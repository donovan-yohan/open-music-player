// Progress message types matching backend WebSocket protocol
export interface ProgressMessage {
  type: 'download_progress';
  job_id: number;
  status: DownloadStatus;
  progress: number;
  track_title?: string;
  artist_name?: string;
  error?: string;
}

export type DownloadStatus = 'pending' | 'downloading' | 'processing' | 'completed' | 'failed';

// Auth token storage
export interface AuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // Unix timestamp in ms
}

// Download job state tracked in the extension
export interface DownloadJobState {
  jobId: number;
  status: DownloadStatus;
  progress: number;
  trackTitle: string;
  artistName: string;
  error?: string;
  startedAt: number;
}

// WebSocket connection state
export type WebSocketState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting';

// Messages between popup and background
export interface ExtensionMessage {
  type: string;
  payload?: unknown;
}

export interface GetDownloadStateRequest extends ExtensionMessage {
  type: 'GET_DOWNLOAD_STATE';
}

export interface GetDownloadStateResponse {
  type: 'DOWNLOAD_STATE';
  jobs: DownloadJobState[];
  wsState: WebSocketState;
}

export interface InitiateDownloadRequest extends ExtensionMessage {
  type: 'INITIATE_DOWNLOAD';
  payload: {
    url: string;
  };
}

export interface InitiateDownloadResponse {
  type: 'DOWNLOAD_INITIATED';
  success: boolean;
  jobId?: number;
  error?: string;
}

export interface SetAuthTokensRequest extends ExtensionMessage {
  type: 'SET_AUTH_TOKENS';
  payload: AuthTokens;
}

export interface ClearAuthTokensRequest extends ExtensionMessage {
  type: 'CLEAR_AUTH_TOKENS';
}

export interface GetAuthStateRequest extends ExtensionMessage {
  type: 'GET_AUTH_STATE';
}

export interface GetAuthStateResponse {
  type: 'AUTH_STATE';
  isAuthenticated: boolean;
  userEmail?: string;
}

export interface LoginRequest extends ExtensionMessage {
  type: 'LOGIN';
  payload: {
    email: string;
    password: string;
  };
}

export interface LoginResponse {
  success: boolean;
  userEmail?: string;
  error?: string;
}

export interface LogoutRequest extends ExtensionMessage {
  type: 'LOGOUT';
}

export interface GetNotificationPrefsRequest extends ExtensionMessage {
  type: 'GET_NOTIFICATION_PREFS';
}

export interface SetNotificationPrefsRequest extends ExtensionMessage {
  type: 'SET_NOTIFICATION_PREFS';
  payload: {
    enabled: boolean;
  };
}

export interface NotificationPrefsResponse {
  type: 'NOTIFICATION_PREFS';
  enabled: boolean;
}

export interface ConnectWSRequest extends ExtensionMessage {
  type: 'CONNECT_WS';
}

export interface DisconnectWSRequest extends ExtensionMessage {
  type: 'DISCONNECT_WS';
}

export interface WSStateChangedMessage {
  type: 'WS_STATE_CHANGED';
  state: WebSocketState;
}

export interface ProgressUpdateMessage {
  type: 'PROGRESS_UPDATE';
  job: DownloadJobState;
}

// Storage keys
export const STORAGE_KEYS = {
  ACCESS_TOKEN: 'accessToken',
  REFRESH_TOKEN: 'refreshToken',
  TOKEN_EXPIRES_AT: 'tokenExpiresAt',
  NOTIFICATIONS_ENABLED: 'notificationsEnabled',
  API_BASE_URL: 'apiBaseUrl',
} as const;

// Default configuration
export const DEFAULT_CONFIG = {
  API_BASE_URL: 'http://localhost:8080',
  WS_RECONNECT_DELAY: 3000,
  WS_MAX_RECONNECT_ATTEMPTS: 5,
} as const;
