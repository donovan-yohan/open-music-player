import type { ProgressMessage, WebSocketState, DownloadJobState } from '../types';

// Configuration
const WS_RECONNECT_DELAY_MS = 3000;
const WS_MAX_RECONNECT_ATTEMPTS = 5;
const WS_PING_INTERVAL_MS = 30000;

export interface WebSocketManagerConfig {
  baseUrl: string;
  onMessage: (message: ProgressMessage) => void;
  onStateChange: (state: WebSocketState) => void;
  getAccessToken: () => Promise<string | null>;
}

export class WebSocketManager {
  private ws: WebSocket | null = null;
  private state: WebSocketState = 'disconnected';
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private config: WebSocketManagerConfig;
  private intentionalClose = false;

  constructor(config: WebSocketManagerConfig) {
    this.config = config;
  }

  async connect(): Promise<void> {
    if (this.state === 'connected' || this.state === 'connecting') {
      return;
    }

    const token = await this.config.getAccessToken();
    if (!token) {
      console.log('[WS] No access token available, skipping connection');
      return;
    }

    this.intentionalClose = false;
    this.setState('connecting');

    const wsUrl = `${this.config.baseUrl}/ws/progress?token=${encodeURIComponent(token)}`;

    try {
      this.ws = new WebSocket(wsUrl);
      this.setupEventHandlers();
    } catch (error) {
      console.error('[WS] Failed to create WebSocket:', error);
      this.handleReconnect();
    }
  }

  disconnect(): void {
    this.intentionalClose = true;
    this.cleanup();
    this.setState('disconnected');
  }

  getState(): WebSocketState {
    return this.state;
  }

  private setupEventHandlers(): void {
    if (!this.ws) return;

    this.ws.onopen = () => {
      console.log('[WS] Connected');
      this.reconnectAttempts = 0;
      this.setState('connected');
      this.startPingTimer();
    };

    this.ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data) as ProgressMessage;
        if (message.type === 'download_progress') {
          this.config.onMessage(message);
        }
      } catch (error) {
        console.error('[WS] Failed to parse message:', error);
      }
    };

    this.ws.onerror = (error) => {
      console.error('[WS] Error:', error);
    };

    this.ws.onclose = (event) => {
      console.log('[WS] Closed:', event.code, event.reason);
      this.cleanup();

      if (!this.intentionalClose) {
        this.handleReconnect();
      }
    };
  }

  private handleReconnect(): void {
    if (this.reconnectAttempts >= WS_MAX_RECONNECT_ATTEMPTS) {
      console.log('[WS] Max reconnect attempts reached');
      this.setState('disconnected');
      return;
    }

    this.setState('reconnecting');
    this.reconnectAttempts++;

    const delay = WS_RECONNECT_DELAY_MS * Math.pow(1.5, this.reconnectAttempts - 1);
    console.log(`[WS] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})`);

    this.reconnectTimer = setTimeout(() => {
      this.connect();
    }, delay);
  }

  private startPingTimer(): void {
    this.stopPingTimer();
    this.pingTimer = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        // The server handles ping/pong at the protocol level
        // We just need to ensure the connection is still alive
        console.log('[WS] Connection alive check');
      }
    }, WS_PING_INTERVAL_MS);
  }

  private stopPingTimer(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  private cleanup(): void {
    this.stopPingTimer();

    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onerror = null;
      this.ws.onclose = null;

      if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) {
        this.ws.close();
      }
      this.ws = null;
    }
  }

  private setState(state: WebSocketState): void {
    if (this.state !== state) {
      this.state = state;
      this.config.onStateChange(state);
    }
  }
}

// Job state manager for tracking active downloads
export class DownloadJobManager {
  private jobs: Map<number, DownloadJobState> = new Map();
  private listeners: Set<(jobs: DownloadJobState[]) => void> = new Set();

  updateJob(message: ProgressMessage): DownloadJobState {
    const existing = this.jobs.get(message.job_id);

    const job: DownloadJobState = {
      jobId: message.job_id,
      status: message.status,
      progress: message.progress,
      trackTitle: message.track_title || existing?.trackTitle || 'Unknown Track',
      artistName: message.artist_name || existing?.artistName || 'Unknown Artist',
      error: message.error,
      startedAt: existing?.startedAt || Date.now(),
    };

    this.jobs.set(message.job_id, job);
    this.notifyListeners();

    // Remove completed/failed jobs after a delay
    if (message.status === 'completed' || message.status === 'failed') {
      setTimeout(() => {
        this.jobs.delete(message.job_id);
        this.notifyListeners();
      }, 5000);
    }

    return job;
  }

  getJobs(): DownloadJobState[] {
    return Array.from(this.jobs.values());
  }

  getJob(jobId: number): DownloadJobState | undefined {
    return this.jobs.get(jobId);
  }

  addListener(listener: (jobs: DownloadJobState[]) => void): void {
    this.listeners.add(listener);
  }

  removeListener(listener: (jobs: DownloadJobState[]) => void): void {
    this.listeners.delete(listener);
  }

  clearJobs(): void {
    this.jobs.clear();
    this.notifyListeners();
  }

  private notifyListeners(): void {
    const jobs = this.getJobs();
    this.listeners.forEach((listener) => listener(jobs));
  }
}
