// Content script for Open Music Player extension
import { PageMetadata, SourceType, MetadataResponse } from './types';

console.log('Open Music Player content script loaded');

function getYouTubeMetadata(): { metadata: PageMetadata; sourceType: SourceType } {
  // Get video title
  let title = '';
  const titleElement = document.querySelector('h1.ytd-video-primary-info-renderer yt-formatted-string') ||
                       document.querySelector('h1.ytd-watch-metadata yt-formatted-string') ||
                       document.querySelector('h1.title');
  if (titleElement) {
    title = titleElement.textContent?.trim() || '';
  }
  if (!title) {
    title = document.title.replace(' - YouTube', '').trim();
  }

  // Get channel name as artist
  let artist = '';
  const channelElement = document.querySelector('#channel-name a') ||
                         document.querySelector('ytd-channel-name a') ||
                         document.querySelector('.ytd-channel-name a');
  if (channelElement) {
    artist = channelElement.textContent?.trim() || '';
  }

  // Get thumbnail from video ID
  let thumbnail = '';
  const videoId = new URL(window.location.href).searchParams.get('v');
  if (videoId) {
    thumbnail = `https://img.youtube.com/vi/${videoId}/maxresdefault.jpg`;
  }

  // Get duration
  let duration = '';
  const durationElement = document.querySelector('.ytp-time-duration');
  if (durationElement) {
    duration = durationElement.textContent?.trim() || '';
  }

  return {
    metadata: { title, thumbnail, artist, duration },
    sourceType: 'youtube'
  };
}

function getSoundCloudMetadata(): { metadata: PageMetadata; sourceType: SourceType } {
  // Get track title
  let title = '';
  const titleElement = document.querySelector('span.soundTitle__title') ||
                       document.querySelector('h1[itemprop="name"]');
  if (titleElement) {
    title = titleElement.textContent?.trim() || '';
  }
  if (!title) {
    const metaTitle = document.querySelector('meta[property="og:title"]') as HTMLMetaElement;
    title = metaTitle?.content || document.title.replace(' | SoundCloud', '').trim();
  }

  // Get artist name
  let artist = '';
  const artistElement = document.querySelector('span.soundTitle__username') ||
                        document.querySelector('a[itemprop="url"]');
  if (artistElement) {
    artist = artistElement.textContent?.trim() || '';
  }

  // Get thumbnail from meta tags
  let thumbnail = '';
  const thumbnailMeta = document.querySelector('meta[property="og:image"]') as HTMLMetaElement;
  if (thumbnailMeta) {
    thumbnail = thumbnailMeta.content;
  }

  // Get duration
  let duration = '';
  const durationMeta = document.querySelector('meta[itemprop="duration"]') as HTMLMetaElement;
  if (durationMeta) {
    duration = durationMeta.content;
  }

  return {
    metadata: { title, thumbnail, artist, duration },
    sourceType: 'soundcloud'
  };
}

function getPageMetadata(): { metadata: PageMetadata; sourceType: SourceType } {
  const hostname = window.location.hostname;

  if (hostname.includes('youtube.com')) {
    return getYouTubeMetadata();
  } else if (hostname.includes('soundcloud.com')) {
    return getSoundCloudMetadata();
  }

  // Unknown source - use generic metadata
  return {
    metadata: { title: document.title },
    sourceType: 'unknown'
  };
}

function isValidMusicPage(): boolean {
  const hostname = window.location.hostname;
  const pathname = window.location.pathname;
  const searchParams = new URL(window.location.href).searchParams;

  // YouTube video page (must have video ID)
  if (hostname.includes('youtube.com') && searchParams.has('v')) {
    return true;
  }

  // SoundCloud track page
  if (hostname.includes('soundcloud.com')) {
    const pathParts = pathname.split('/').filter(Boolean);
    // Valid track URL format: /username/track-name (2 parts, not special pages)
    const specialPages = ['discover', 'stream', 'library', 'you', 'charts', 'search', 'stations', 'upload', 'messages', 'settings'];
    if (pathParts.length >= 2 &&
        !specialPages.includes(pathParts[0]) &&
        !pathParts.includes('sets') &&
        !pathParts.includes('likes') &&
        !pathParts.includes('followers') &&
        !pathParts.includes('following') &&
        !pathParts.includes('reposts')) {
      return true;
    }
  }

  return false;
}

// Listen for messages from popup or background
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === 'GET_PAGE_METADATA') {
    const { metadata, sourceType } = getPageMetadata();
    const supported = isValidMusicPage();

    const response: MetadataResponse = {
      type: 'PAGE_METADATA',
      url: window.location.href,
      sourceType,
      metadata,
      supported
    };

    sendResponse(response);
  }
  return true;
});

function init(): void {
  console.log('Open Music Player: Ready to extract metadata');
}

init();
