"""Verify the packaged yt-dlp override without making any network requests."""
from typing import cast
from unittest.mock import patch

from yt_dlp import YoutubeDL
from yt_dlp.extractor.soundcloud import SoundcloudBaseIE


artwork = {'id': 1, 'artwork_url': 'https://fixture.invalid/cover-large.jpg'}
with YoutubeDL({'quiet': True}) as ydl:
    search = cast(SoundcloudBaseIE, ydl.get_info_extractor('SoundcloudSearch'))
    with patch.object(search, '_request_webpage', side_effect=AssertionError(
            'SoundCloud search probes original artwork synchronously')):
        thumbnails = search._extract_thumbnails(artwork)
    assert any(item['url'] == 'https://fixture.invalid/cover-crop.jpg' and item['height'] == 400
               for item in thumbnails), 'Discover lost the sized artwork'

    direct = cast(SoundcloudBaseIE, ydl.get_info_extractor('Soundcloud'))
    with patch.object(direct, '_request_webpage', return_value=True) as probe:
        thumbnails = direct._extract_thumbnails(artwork)
    probe.assert_called_once()
    assert probe.call_args.args[0].method == 'HEAD'
    assert any(item['id'] == 'original' for item in thumbnails), 'Direct track extraction changed'
