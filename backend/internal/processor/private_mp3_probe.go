package processor

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"time"
)

const privateMP3MaxSeconds = 30 * 60

type privateMP3Frames struct {
	rate, channels, samples int64
}

// Reject resynchronization, junk, extra streams, unsupported headers, and
// unbounded tag/decoded data even when a demuxer would salvage some audio.
// The admitted profile is optional bounded ID3v2.3/4, contiguous Layer III
// frames with fixed PCM dimensions (VBR allowed), and optional final ID3v1.
func scanPrivateMP3(ctx context.Context, input io.Reader) (privateMP3Frames, error) {
	var facts privateMP3Frames
	r := bufio.NewReader(input)
	if magic, _ := r.Peek(3); string(magic) == "ID3" {
		const maxTag = 1 << 20
		header, err := r.Peek(10)
		if err != nil || (header[3] != 3 && header[3] != 4) || header[4] != 0 || header[5] != 0 {
			return facts, ErrPrivateIntakeProbe
		}
		var size int
		for _, octet := range header[6:10] {
			if octet > 127 {
				return facts, ErrPrivateIntakeProbe
			}
			size = (size << 7) | int(octet)
		}
		if size > maxTag {
			return facts, ErrPrivateIntakeProbe
		}
		if _, err := r.Discard(10 + size); err != nil {
			return facts, ErrPrivateIntakeProbe
		}
	}
	var frames int
	for {
		if err := ctx.Err(); err != nil {
			return facts, err
		}
		header, err := r.Peek(4)
		if err == io.EOF && len(header) == 0 {
			break
		}
		if err != nil {
			return facts, ErrPrivateIntakeProbe
		}
		if string(header[:3]) == "TAG" {
			if _, err := r.Discard(128); err != nil {
				return facts, ErrPrivateIntakeProbe
			}
			if _, err := r.Peek(1); err != io.EOF {
				return facts, ErrPrivateIntakeProbe
			}
			break
		}
		rate, channels, samples, length := privateMP3Frame(binary.BigEndian.Uint32(header))
		if length == 0 || (frames != 0 && (rate != facts.rate || channels != facts.channels)) {
			return facts, ErrPrivateIntakeProbe
		}
		facts.rate, facts.channels = rate, channels
		facts.samples += samples
		if facts.samples > facts.rate*privateMP3MaxSeconds {
			return facts, ErrPrivateIntakeProbe
		}
		if _, err := r.Discard(length); err != nil {
			return facts, ErrPrivateIntakeProbe
		}
		frames++
	}
	if frames < 2 {
		return facts, ErrPrivateIntakeProbe
	}
	return facts, nil
}

func privateMP3Frame(header uint32) (rate, channels, samples int64, length int) {
	version, layer := (header>>19)&3, (header>>17)&3
	bitrateIndex, rateIndex := (header>>12)&15, (header>>10)&3
	if header>>21 != 0x7ff || version == 1 || layer != 1 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3 || header&3 == 2 {
		return 0, 0, 0, 0
	}
	rate = [3]int64{44100, 48000, 32000}[rateIndex]
	bitrate := [15]int64{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}[bitrateIndex]
	samples = 1152
	if version != 3 {
		rate /= 2
		if version == 0 {
			rate /= 2
		}
		samples = 576
		bitrate = [15]int64{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}[bitrateIndex]
	}
	channels = 2
	if (header>>6)&3 == 3 {
		channels = 1
	}
	length = int((samples/8)*bitrate*1000/rate + int64((header>>9)&1))
	return
}

type privatePCMCount struct{ max, count int64 }

func (w *privatePCMCount) Write(p []byte) (int, error) {
	if int64(len(p)) > w.max-w.count {
		return 0, ErrPrivateIntakeProbe
	}
	w.count += int64(len(p))
	return len(p), nil
}

func probePrivateMP3(ctx context.Context, ffmpeg string, spool *os.File) (int32, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	facts, err := scanPrivateMP3(ctx, spool)
	if err != nil {
		return 0, err
	}
	if _, err := spool.Seek(0, io.SeekStart); err != nil {
		return 0, ErrPrivateIntakeProbe
	}
	// No pathname, URL, automatic demuxer/decoder selection or metadata
	// output. Decode through one pipe; count PCM without buffering it. MP3
	// tags (including references/artwork) never supply another input.
	cmd := exec.CommandContext(ctx, ffmpeg, "-v", "error", "-nostdin", "-xerror", "-max_alloc", "16777216",
		"-protocol_whitelist", "pipe", "-probesize", "32768", "-analyzeduration", "1000000",
		"-err_detect", "crccheck+explode", "-threads", "1", "-f", "mp3", "-c:a", "mp3", "-i", "pipe:0",
		"-map", "0:a:0", "-vn", "-sn", "-dn", "-c:a", "pcm_s16le", "-threads", "1", "-f", "s16le", "pipe:1")
	cmd.Env = []string{"LC_ALL=C"}
	cmd.Stdin = spool
	count := privatePCMCount{max: facts.samples * facts.channels * 2}
	cmd.Stdout, cmd.Stderr = &count, io.Discard
	cmd.WaitDelay = time.Second
	if err := cmd.Run(); err != nil || ctx.Err() != nil || count.count%(facts.channels*2) != 0 {
		return 0, ErrPrivateIntakeProbe
	}
	ms := (count.count/(facts.channels*2)*1000 + facts.rate/2) / facts.rate
	if ms == 0 || ms > privateMP3MaxSeconds*1000 {
		return 0, ErrPrivateIntakeProbe
	}
	if _, err := spool.Seek(0, io.SeekStart); err != nil {
		return 0, ErrPrivateIntakeProbe
	}
	return int32(ms), nil
}
