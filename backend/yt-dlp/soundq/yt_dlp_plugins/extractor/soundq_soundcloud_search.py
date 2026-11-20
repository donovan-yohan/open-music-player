from yt_dlp.extractor.soundcloud import SoundcloudSearchIE


class SoundQSoundCloudSearchIE(SoundcloudSearchIE, plugin_name='soundq-search'):
    # Flat search otherwise HEAD-probes each track's original artwork before
    # emitting it. Discover uses the sized variants; an optional CDN probe
    # must not consume the search budget. Leave direct track extraction alone.
    _ARTWORK_MAP = {
        name: size for name, size in SoundcloudSearchIE._ARTWORK_MAP.items()
        if name != 'original'
    }
