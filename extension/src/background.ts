// Service worker for Sound Q extension
import type {
  AddToLibraryMessage,
  AddToLibraryResponse,
  DownloadRequest,
  DownloadResponse,
  MetadataResponse,
  AuthState,
} from './types';
import { AppError, ErrorCodes, toAppError } from './errors';
import { apiClient } from './utils/api';
import { getAuthTokens, saveAccessToken, clearAuthTokens } from './storage';

const API_BASE_URL = 'https://soundq.fish-rattlesnake.ts.net/api/v1';
const CONTEXT_MENU_ID = 'add-to-omp';

// Backend availability state
let backendAvailable = true;
let lastBackendCheck = 0;
const BACKEND_CHECK_INTERVAL = 30000; // 30 seconds

/**
 * Records the outcome of a request against the backend so the cached
 * availability probe stays fresh (mirrors the tracking the previous inline
 * fetch/retry helper performed).
 */
function markBackendReachable(reachable: boolean): void {
  backendAvailable = reachable;
  lastBackendCheck = Date.now();
}

// Check backend availability
async function checkBackendAvailability(): Promise<boolean> {
  // Use cached result if recent
  if (Date.now() - lastBackendCheck < BACKEND_CHECK_INTERVAL) {
    return backendAvailable;
  }

  try {
    const response = await fetch(`${API_BASE_URL.replace('/api/v1', '')}/health`, {
      method: 'GET',
    });
    backendAvailable = response.ok;
  } catch {
    backendAvailable = false;
  }

  lastBackendCheck = Date.now();
  return backendAvailable;
}

// Parse API error response
function parseApiError(response: Response, body?: unknown): { code: string; message: string } {
  return AppError.fromApiResponse(response, body);
}

const TRANSIENT_REFRESH_ERROR = 'Authentication refresh temporarily unavailable. Please try again.';

function isAuthInvalidResponse(response: Response, code: string): boolean {
  return response.status === 401 ||
    code === ErrorCodes.UNAUTHORIZED ||
    code === ErrorCodes.INVALID_TOKEN ||
    code === ErrorCodes.TOKEN_EXPIRED;
}

function isAuthInvalidDueToTransientRefresh(response: Response, code: string): boolean {
  return isAuthInvalidResponse(response, code) && apiClient.wasRefreshFailureTransient(response);
}

async function clearAuthTokensForInvalidSession(response: Response, code: string): Promise<boolean> {
  if (!isAuthInvalidResponse(response, code) || apiClient.wasRefreshFailureTransient(response)) {
    return false;
  }

  await clearAuthTokens();
  return true;
}

// Check if user is logged in. Token storage + validity now live in the unified
// ApiClient/storage layer; a stored access token means "logged in". Actual
// staleness is resolved lazily by the ApiClient's refresh-on-401 on the next
// authenticated request, so no separate /auth/validate probe is needed.
async function checkAuth(): Promise<AuthState> {
  const tokens = await getAuthTokens();
  if (!tokens?.accessToken) {
    return { isLoggedIn: false };
  }
  return { isLoggedIn: true, token: tokens.accessToken };
}

// Add track to library via API
async function addToLibrary(
  message: AddToLibraryMessage
): Promise<AddToLibraryResponse> {
  // Check backend availability first
  const isAvailable = await checkBackendAvailability();
  if (!isAvailable) {
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: 'backend_unavailable',
      errorCode: ErrorCodes.NETWORK_ERROR,
    };
  }

  const auth = await checkAuth();

  if (!auth.isLoggedIn || !auth.token) {
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: 'not_logged_in',
    };
  }

  const requestBody: DownloadRequest = {
    url: message.url,
    source_type: message.sourceType,
    page_metadata: {
      title: message.metadata.title,
      thumbnail: message.metadata.thumbnail,
    },
  };

  try {
    const response = await apiClient.authorizedFetch('/api/v1/downloads', {
      method: 'POST',
      body: JSON.stringify(requestBody),
    });
    markBackendReachable(true);

    if (response.ok) {
      const data: DownloadResponse = await response.json();
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: true,
        jobId: data.job_id,
      };
    }

    // Parse error body
    const errorBody = await response.json().catch(() => undefined);
    const { code, message: errorMessage } = parseApiError(response, errorBody);

    // Handle specific error codes
    if (isAuthInvalidDueToTransientRefresh(response, code)) {
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: false,
        error: TRANSIENT_REFRESH_ERROR,
        errorCode: ErrorCodes.NETWORK_ERROR,
      };
    }

    if (await clearAuthTokensForInvalidSession(response, code)) {
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: false,
        error: 'not_logged_in',
      };
    }

    if (response.status === 409 || code === ErrorCodes.CONFLICT) {
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: false,
        error: 'already_added',
      };
    }

    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: errorMessage,
      errorCode: code,
    };
  } catch (err) {
    markBackendReachable(false);
    const appError = toAppError(err);
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: appError.displayMessage,
      errorCode: appError.code,
    };
  }
}

// Get metadata from content script
async function getMetadataFromTab(tabId: number): Promise<MetadataResponse | null> {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(
      tabId,
      { type: 'GET_PAGE_METADATA' },
      (response: MetadataResponse | undefined) => {
        if (chrome.runtime.lastError) {
          console.error('Error getting metadata:', chrome.runtime.lastError);
          resolve(null);
        } else {
          resolve(response || null);
        }
      }
    );
  });
}

// Handle add from context menu or keyboard shortcut
async function handleAddFromContext(tab: chrome.tabs.Tab): Promise<void> {
  if (!tab.id || !tab.url) {
    console.error('No active tab');
    return;
  }

  // Check if URL is supported
  const isSupported =
    tab.url.includes('youtube.com/watch') ||
    tab.url.includes('soundcloud.com/');

  if (!isSupported) {
    console.log('URL not supported:', tab.url);
    return;
  }

  // Get metadata from content script
  const metadata = await getMetadataFromTab(tab.id);
  if (!metadata || !metadata.supported) {
    console.log('Could not get metadata or page not supported');
    return;
  }

  // Add to library
  const result = await addToLibrary({
    type: 'ADD_TO_LIBRARY',
    url: metadata.url,
    sourceType: metadata.sourceType,
    metadata: metadata.metadata,
  });

  // Log result
  if (result.success) {
    console.log('Added to library, job ID:', result.jobId);
  } else {
    console.log('Failed to add:', result.error);
  }
}

// Create context menu on install
chrome.runtime.onInstalled.addListener(() => {
  console.log('Sound Q extension installed');

  // Create context menu item
  chrome.contextMenus.create({
    id: CONTEXT_MENU_ID,
    title: 'Add to Sound Q',
    contexts: ['page'],
    documentUrlPatterns: [
      'https://www.youtube.com/*',
      'https://youtube.com/*',
      'https://soundcloud.com/*',
      'https://www.soundcloud.com/*',
    ],
  });
});

// Handle context menu click
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === CONTEXT_MENU_ID && tab) {
    handleAddFromContext(tab);
  }
});

// Handle keyboard shortcut
chrome.commands.onCommand.addListener((command) => {
  if (command === 'add-to-library') {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0]) {
        handleAddFromContext(tabs[0]);
      }
    });
  }
});

// Handle messages from popup
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === 'PING') {
    sendResponse({ type: 'PONG' });
    return true;
  }

  if (message.type === 'CHECK_BACKEND') {
    checkBackendAvailability().then((available) => {
      sendResponse({ available });
    });
    return true;
  }

  if (message.type === 'CHECK_AUTH') {
    checkAuth().then(sendResponse);
    return true;
  }

  if (message.type === 'ADD_TO_LIBRARY') {
    addToLibrary(message as AddToLibraryMessage).then(sendResponse);
    return true;
  }

  if (message.type === 'SET_AUTH_TOKEN') {
    saveAccessToken(message.token).then(() => {
      sendResponse({ success: true });
    });
    return true;
  }

  if (message.type === 'LOGOUT') {
    clearAuthTokens().then(() => {
      sendResponse({ success: true });
    });
    return true;
  }

  if (message.type === 'UPDATE_METADATA') {
    // The backend's per-user metadata-override API is not this legacy contract.
    sendResponse({
      type: 'UPDATE_METADATA_RESULT', success: false,
      error: 'Metadata editing is not supported by this extension. Use the Sound Q app.',
    });
    return true;
  }

  if (message.type === 'MERGE_TRACKS') {
    // No track-merge route is registered by the backend.
    sendResponse({ success: false, error: 'Track merging is not supported by this extension.' });
    return true;
  }

  return false;
});
