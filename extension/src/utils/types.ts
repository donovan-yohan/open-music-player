export type SourceType = 'youtube' | 'soundcloud';

export interface PageMetadata {
  url: string;
  sourceType: SourceType;
  title: string;
  artist?: string;
  thumbnail?: string;
  duration?: number;
}

export type BadgeState = 'disabled' | 'ready' | 'added';

export interface UrlDetectionResult {
  supported: boolean;
  sourceType?: SourceType;
  videoId?: string;
  trackPath?: string;
}
