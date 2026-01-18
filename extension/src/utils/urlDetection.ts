import { SourceType, UrlDetectionResult } from './types';

const YOUTUBE_PATTERNS = [
  /^https?:\/\/(www\.)?youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]+)/,
  /^https?:\/\/youtu\.be\/([a-zA-Z0-9_-]+)/,
  /^https?:\/\/music\.youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]+)/,
];

const SOUNDCLOUD_PATTERN = /^https?:\/\/(www\.)?soundcloud\.com\/([^/]+)\/([^/?]+)/;

export function detectUrl(url: string): UrlDetectionResult {
  for (const pattern of YOUTUBE_PATTERNS) {
    const match = url.match(pattern);
    if (match) {
      const videoId = match[2] || match[1];
      return {
        supported: true,
        sourceType: 'youtube',
        videoId,
      };
    }
  }

  const soundcloudMatch = url.match(SOUNDCLOUD_PATTERN);
  if (soundcloudMatch) {
    const trackPath = `${soundcloudMatch[2]}/${soundcloudMatch[3]}`;
    return {
      supported: true,
      sourceType: 'soundcloud',
      trackPath,
    };
  }

  return { supported: false };
}

export function isYouTubeUrl(url: string): boolean {
  return YOUTUBE_PATTERNS.some((pattern) => pattern.test(url));
}

export function isSoundCloudUrl(url: string): boolean {
  return SOUNDCLOUD_PATTERN.test(url);
}

export function getSourceType(url: string): SourceType | null {
  if (isYouTubeUrl(url)) return 'youtube';
  if (isSoundCloudUrl(url)) return 'soundcloud';
  return null;
}
