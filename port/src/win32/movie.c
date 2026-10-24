// Bink movie decoding on FFmpeg, for the binkw32.dll HLE (bink.odin).
// Written in C so that FFmpeg's structs are read through its own headers:
// their layouts change between major versions. Built by build.sh into
// build/libmovie.a.
// WHY: docs/hle.md §4
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Packets read for one video frame before the file is treated as corrupt.
// A Bink frame is one video packet plus one packet per audio track.
#define MOVIE_PACKETS_PER_FRAME 4096
#define MOVIE_AUDIO_CHANNELS 2

typedef struct Movie_Info {
	int32_t w, h, frames, fps_num, fps_den, rate, channels;
} Movie_Info;

typedef struct Movie {
	AVFormatContext *fmt;
	AVCodecContext *vdec, *adec;
	int vstream, astream;
	AVPacket *pkt;
	AVFrame *vframe, *aframe;
	int have_frame; // vframe holds a decoded picture
	int eof;        // demuxer exhausted, decoders flushed
	SwsContext *sws;
	SwrContext *swr;
	float *audio;   // interleaved stereo f32 decoded since the last take
	int audio_n;    // samples (frames of MOVIE_AUDIO_CHANNELS floats)
	int audio_cap;
} Movie;

static char movie_err[256];

const char *movie_error(void) { return movie_err; }

static int fail(int code, const char *what) {
	char buf[128];
	av_strerror(code, buf, sizeof buf);
	snprintf(movie_err, sizeof movie_err, "%s: %s", what, buf);
	return -1;
}

static AVCodecContext *open_decoder(AVStream *st) {
	const AVCodec *c = avcodec_find_decoder(st->codecpar->codec_id);
	if (!c) {
		snprintf(movie_err, sizeof movie_err, "no decoder for codec %d", st->codecpar->codec_id);
		return NULL;
	}
	AVCodecContext *d = avcodec_alloc_context3(c);
	assert(d);
	int e = avcodec_parameters_to_context(d, st->codecpar);
	if (e >= 0) e = avcodec_open2(d, c, NULL);
	if (e < 0) {
		fail(e, "open decoder");
		avcodec_free_context(&d);
	}
	return d;
}

void movie_close(Movie *m) {
	if (!m) return;
	sws_freeContext(m->sws);
	swr_free(&m->swr);
	av_frame_free(&m->vframe);
	av_frame_free(&m->aframe);
	av_packet_free(&m->pkt);
	avcodec_free_context(&m->vdec);
	avcodec_free_context(&m->adec);
	avformat_close_input(&m->fmt);
	av_free(m->audio);
	av_free(m);
}

// Opens path. With audio != 0 the first audio track is decoded as well.
// Returns NULL with movie_error() set on failure.
Movie *movie_open(const char *path, int audio, Movie_Info *info) {
	av_log_set_level(AV_LOG_ERROR);
	Movie *m = av_mallocz(sizeof *m);
	assert(m);
	m->vstream = m->astream = -1;
	int e = avformat_open_input(&m->fmt, path, NULL, NULL);
	if (e < 0) { fail(e, "open"); av_free(m); return NULL; }
	e = avformat_find_stream_info(m->fmt, NULL);
	if (e < 0) { fail(e, "stream info"); movie_close(m); return NULL; }
	m->vstream = av_find_best_stream(m->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
	if (m->vstream < 0) { fail(m->vstream, "video stream"); movie_close(m); return NULL; }
	AVStream *vs = m->fmt->streams[m->vstream];
	m->vdec = open_decoder(vs);
	if (!m->vdec) { movie_close(m); return NULL; }
	memset(info, 0, sizeof *info);
	if (audio) {
		m->astream = av_find_best_stream(m->fmt, AVMEDIA_TYPE_AUDIO, -1, m->vstream, NULL, 0);
		if (m->astream >= 0) {
			AVStream *as = m->fmt->streams[m->astream];
			m->adec = open_decoder(as);
			if (!m->adec) { movie_close(m); return NULL; }
			AVChannelLayout out = AV_CHANNEL_LAYOUT_STEREO;
			e = swr_alloc_set_opts2(&m->swr, &out, AV_SAMPLE_FMT_FLT, m->adec->sample_rate,
				&m->adec->ch_layout, m->adec->sample_fmt, m->adec->sample_rate, 0, NULL);
			if (e >= 0) e = swr_init(m->swr);
			if (e < 0) { fail(e, "resampler"); movie_close(m); return NULL; }
			info->rate = m->adec->sample_rate;
			info->channels = MOVIE_AUDIO_CHANNELS;
		}
	}
	m->pkt = av_packet_alloc();
	m->vframe = av_frame_alloc();
	m->aframe = av_frame_alloc();
	assert(m->pkt && m->vframe && m->aframe);
	info->w = m->vdec->width;
	info->h = m->vdec->height;
	AVRational r = vs->avg_frame_rate.num > 0 ? vs->avg_frame_rate : av_inv_q(vs->time_base);
	// Bink stores the frame count as the stream duration in frame units;
	// Matroska has neither, only the container duration.
	int64_t frames = vs->nb_frames > 0 ? vs->nb_frames : vs->duration;
	if (frames <= 0 && m->fmt->duration > 0 && r.num > 0)
		frames = av_rescale_q_rnd(m->fmt->duration, AV_TIME_BASE_Q, av_inv_q(r), AV_ROUND_NEAR_INF);
	info->frames = (int32_t)frames;
	info->fps_num = r.num;
	info->fps_den = r.den;
	if (info->w <= 0 || info->h <= 0 || info->frames <= 0 || r.num <= 0 || r.den <= 0) {
		snprintf(movie_err, sizeof movie_err, "bad header: %dx%d, %d frames, %d/%d fps",
			info->w, info->h, info->frames, r.num, r.den);
		movie_close(m);
		return NULL;
	}
	return m;
}

static int audio_append(Movie *m) {
	int n = swr_get_out_samples(m->swr, m->aframe->nb_samples);
	if (n < 0) return fail(n, "resample size");
	if (m->audio_n + n > m->audio_cap) {
		int cap = (m->audio_n + n) * 2;
		float *a = av_realloc(m->audio, (size_t)cap * MOVIE_AUDIO_CHANNELS * sizeof(float));
		assert(a);
		m->audio = a;
		m->audio_cap = cap;
	}
	uint8_t *out = (uint8_t *)(m->audio + (size_t)m->audio_n * MOVIE_AUDIO_CHANNELS);
	int got = swr_convert(m->swr, &out, n, (const uint8_t **)m->aframe->extended_data, m->aframe->nb_samples);
	if (got < 0) return fail(got, "resample");
	m->audio_n += got;
	return 0;
}

static int audio_packet(Movie *m, AVPacket *p) {
	int e = avcodec_send_packet(m->adec, p);
	if (e < 0 && e != AVERROR_EOF) return fail(e, "audio decode");
	for (int k = 0; k < MOVIE_PACKETS_PER_FRAME; k++) {
		e = avcodec_receive_frame(m->adec, m->aframe);
		if (e == AVERROR(EAGAIN) || e == AVERROR_EOF) return 0;
		if (e < 0) return fail(e, "audio decode");
		if (audio_append(m) < 0) return -1;
	}
	snprintf(movie_err, sizeof movie_err, "audio decoder produced too many frames");
	return -1;
}

// Decodes the next video frame. Audio packets met on the way are decoded and
// queued for movie_audio. Returns 1 for a frame, 0 at the end, -1 on error.
int movie_decode(Movie *m) {
	for (int k = 0; k < MOVIE_PACKETS_PER_FRAME; k++) {
		int e = avcodec_receive_frame(m->vdec, m->vframe);
		if (e >= 0) { m->have_frame = 1; return 1; }
		if (e == AVERROR_EOF) return 0;
		if (e != AVERROR(EAGAIN)) return fail(e, "video decode");
		if (m->eof) return 0;
		e = av_read_frame(m->fmt, m->pkt);
		if (e == AVERROR_EOF) {
			// Flushed decoders return their last frames, then EOF, never EAGAIN.
			m->eof = 1;
			if (m->adec && audio_packet(m, NULL) < 0) return -1;
			e = avcodec_send_packet(m->vdec, NULL);
			if (e < 0) return fail(e, "video flush");
			continue;
		}
		if (e < 0) return fail(e, "read");
		if (m->pkt->stream_index == m->vstream) {
			e = avcodec_send_packet(m->vdec, m->pkt);
			av_packet_unref(m->pkt);
			if (e < 0) return fail(e, "video decode");
		} else if (m->pkt->stream_index == m->astream) {
			e = audio_packet(m, m->pkt);
			av_packet_unref(m->pkt);
			if (e < 0) return -1;
		} else {
			av_packet_unref(m->pkt);
		}
	}
	snprintf(movie_err, sizeof movie_err, "no video frame in %d packets", MOVIE_PACKETS_PER_FRAME);
	return -1;
}

// Converts the last decoded frame into dst, w x h pixels of pitch bytes per
// line, in fmt. A size other than the movie's is scaled with Lanczos, on all
// cores. Returns 0, or -1.
// WHY: docs/hle.md §4
int movie_copy(Movie *m, uint8_t *dst, int pitch, int w, int h, int fmt) {
	static const enum AVPixelFormat PIX[] = {AV_PIX_FMT_BGRA, AV_PIX_FMT_RGB565LE, AV_PIX_FMT_RGB555LE};
	if (fmt < 0 || fmt > 2 || w <= 0 || h <= 0) {
		snprintf(movie_err, sizeof movie_err, "bad copy: format %d, %dx%d", fmt, w, h);
		return -1;
	}
	if (!m->have_frame) return 0;
	if (!m->sws) {
		m->sws = sws_alloc_context();
		assert(m->sws);
		m->sws->threads = 0;
		m->sws->scaler = SWS_SCALE_LANCZOS;
	}
	// A zeroed AVFrame has reserved (invalid) color properties; the frame
	// defaults are "unspecified".
	AVFrame *out = av_frame_alloc();
	assert(out);
	out->format = PIX[fmt];
	out->width = w;
	out->height = h;
	out->data[0] = dst;
	out->linesize[0] = pitch;
	int e = sws_scale_frame(m->sws, out, m->vframe);
	av_frame_free(&out);
	if (e < 0) return fail(e, "convert");
	return 0;
}

// Restarts at the first frame, for a looping movie.
int movie_rewind(Movie *m) {
	int e = av_seek_frame(m->fmt, m->vstream, 0, AVSEEK_FLAG_BACKWARD);
	if (e < 0) return fail(e, "seek");
	avcodec_flush_buffers(m->vdec);
	if (m->adec) avcodec_flush_buffers(m->adec);
	m->eof = 0;
	m->have_frame = 0;
	m->audio_n = 0;
	return 0;
}

// Takes the audio decoded since the previous take: *data points at n
// interleaved stereo f32 samples, valid until the next movie_decode.
int movie_audio(Movie *m, const float **data) {
	*data = m->audio;
	int n = m->audio_n;
	m->audio_n = 0;
	return n;
}
