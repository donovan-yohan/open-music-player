package preview

import "encoding/binary"

func validMP3(data []byte, rate, frames int) bool {
	return frames > 0 && mp3Frames(data, rate) == frames
}

// mp3Frames derives the exact gapless extent of the bounded MPEG-1 Layer III
// envelope expected by the existing Android reader. Zero means invalid.
func mp3Frames(data []byte, rate int) int {
	if len(data) > maxClipBytes || (rate != 44100 && rate != 48000) {
		return 0
	}
	const packetFrames = 1152
	firstSize, channels := mp3Packet(data, rate)
	marker := 36
	if channels == 1 {
		marker = 21
	}
	if firstSize < marker+16 {
		return 0
	}
	tag := data[marker:firstSize]
	if string(tag[:4]) != "Xing" && string(tag[:4]) != "Info" {
		return 0
	}
	flags := binary.BigEndian.Uint32(tag[4:8])
	if flags&3 != 3 || flags > 15 {
		return 0
	}
	encoder := 16
	if flags&4 != 0 {
		encoder += 100
	}
	if flags&8 != 0 {
		encoder += 4
	}
	if len(tag) < encoder+36 {
		return 0
	}
	gapless := tag[encoder:]
	if string(gapless[:4]) != "LAME" && string(gapless[:4]) != "Lavc" {
		return 0
	}
	delay := int64(gapless[21])<<4 | int64(gapless[22])>>4
	padding := int64(gapless[22]&15)<<8 | int64(gapless[23])
	packets := int64(binary.BigEndian.Uint32(tag[8:12]))
	frames := packets*packetFrames - delay - padding
	if packets == 0 || int64(binary.BigEndian.Uint32(tag[12:16])) != int64(len(data)) ||
		padding < 529 || frames < 1 || frames > int64(maxSeconds*rate) {
		return 0
	}
	// After the tag, count every complete packet with the same rate and channel
	// count. The duration check bounds even a forged Xing packet count.
	tail := data[firstSize:]
	for range packets {
		length, ch := mp3Packet(tail, rate)
		if length == 0 || ch != channels {
			return 0
		}
		tail = tail[length:]
	}
	if len(tail) != 0 {
		return 0
	}
	return int(frames)
}

func mp3Packet(data []byte, rate int) (length, channels int) {
	if len(data) < 4 || data[0] != 0xff || data[1] != 0xfb || data[3]&3 == 2 {
		return 0, 0
	}
	kbps := [...]int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
	rates := [...]int{44100, 48000, 32000, 0}
	bitrate := kbps[data[2]>>4]
	if bitrate == 0 || rates[(data[2]>>2)&3] != rate {
		return 0, 0
	}
	length = 144000*bitrate/rate + int((data[2]>>1)&1)
	if length > len(data) {
		return 0, 0
	}
	if data[3]>>6 == 3 {
		return length, 1
	}
	return length, 2
}
