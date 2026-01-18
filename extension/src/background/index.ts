import { WebSocketManager, DownloadJobManager } from '../websocket';
import { getAccessToken, getApiBaseUrl, setAuthTokens, clearAuthTokens } from '../storage';
import { showDownloadCompleteNotification, showDownloadErrorNotification, setupNotificationHandlers } from '../notifications';
import type { ProgressMessage, WebSocketState, DownloadJobState, AuthTokens } from '../types';

// Global state
let wsManager: WebSocketManager | null = null;
let jobManager: DownloadJobManager | null = null;
let currentWsState: WebSocketState = 'disconnected';

// Initialize the extension
async function initialize(): Promise<void> {
  console.log('[Background] Initializing Open Music Player extension');

  // Setup notification handlers
  setupNotificationHandlers();

  // Initialize job manager
  jobManager = new DownloadJobManager();

  // Initialize WebSocket manager
  const baseUrl = await getApiBaseUrl();
  wsManager = new WebSocketManager({
    baseUrl,
    onMessage: handleProgressMessage,
    onStateChange: handleWsStateChange,
    getAccessToken,
  });

  // Try to connect if we have tokens
  const token = await getAccessToken();
  if (token) {
    wsManager.connect();
  }
}

function handleProgressMessage(message: ProgressMessage): void {
  if (!jobManager) return;

  const job = jobManager.updateJob(message);

  // Show notifications for completion/error
  if (message.status === 'completed') {
    showDownloadCompleteNotification(job);
  } else if (message.status === 'failed') {
    showDownloadErrorNotification(job);
  }

  // Broadcast to popup if open
  broadcastToPopup({
    type: 'PROGRESS_UPDATE',
    job,
  });
}

function handleWsStateChange(state: WebSocketState): void {
  console.log('[Background] WebSocket state changed:', state);
  currentWsState = state;

  // Broadcast state change to popup
  broadcastToPopup({
    type: 'WS_STATE_CHANGE',
    state,
  });
}

function broadcastToPopup(message: unknown): void {
  chrome.runtime.sendMessage(message).catch(() => {
    // Popup is not open, ignore
  });
}

// Handle messages from popup and content scripts
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message, sender, sendResponse);
  return true; // Keep the message channel open for async response
});

async function handleMessage(
  message: { type: string; payload?: unknown },
  sender: chrome.runtime.MessageSender,
  sendResponse: (response: unknown) => void
): Promise<void> {
  switch (message.type) {
    case 'PING':
      sendResponse({ type: 'PONG' });
      break;

    case 'GET_DOWNLOAD_STATE':
      sendResponse({
        type: 'DOWNLOAD_STATE',
        jobs: jobManager?.getJobs() || [],
        wsState: currentWsState,
      });
      break;

    case 'GET_AUTH_STATE':
      const token = await getAccessToken();
      sendResponse({
        type: 'AUTH_STATE',
        isAuthenticated: !!token,
      });
      break;

    case 'SET_AUTH_TOKENS':
      await setAuthTokens(message.payload as AuthTokens);
      // Connect WebSocket after receiving tokens
      if (wsManager) {
        wsManager.connect();
      }
      sendResponse({ success: true });
      break;

    case 'CLEAR_AUTH_TOKENS':
      await clearAuthTokens();
      // Disconnect WebSocket
      if (wsManager) {
        wsManager.disconnect();
      }
      sendResponse({ success: true });
      break;

    case 'INITIATE_DOWNLOAD':
      const downloadResult = await initiateDownload((message.payload as { url: string }).url);
      sendResponse(downloadResult);
      break;

    case 'RECONNECT_WS':
      if (wsManager) {
        wsManager.disconnect();
        wsManager.connect();
      }
      sendResponse({ success: true });
      break;

    default:
      sendResponse({ error: 'Unknown message type' });
  }
}

async function initiateDownload(url: string): Promise<{ success: boolean; jobId?: number; error?: string }> {
  const token = await getAccessToken();
  if (!token) {
    return { success: false, error: 'Not authenticated' };
  }

  try {
    const baseUrl = await getApiBaseUrl();
    // Convert ws:// to http:// for REST calls
    const httpBaseUrl = baseUrl.replace('ws://', 'http://').replace('wss://', 'https://');

    const response = await fetch(`${httpBaseUrl}/download`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ url }),
    });

    if (!response.ok) {
      const error = await response.json();
      return { success: false, error: error.message || 'Failed to initiate download' };
    }

    const data = await response.json();
    return { success: true, jobId: data.id };
  } catch (error) {
    console.error('[Background] Download initiation failed:', error);
    return { success: false, error: 'Network error' };
  }
}

// Initialize on install and startup
chrome.runtime.onInstalled.addListener(() => {
  console.log('[Background] Open Music Player extension installed');
  initialize();
});

chrome.runtime.onStartup.addListener(() => {
  console.log('[Background] Open Music Player extension starting up');
  initialize();
});

// Also initialize immediately for development reloads
initialize();
