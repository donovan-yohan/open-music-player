// Service worker for Open Music Player extension
import type {
  AddToLibraryMessage,
  AddToLibraryResponse,
  DownloadRequest,
  DownloadResponse,
  MetadataResponse,
  AuthState,
  UpdateMetadataMessage,
  UpdateMetadataResult,
  UpdateMetadataRequest,
  UpdateMetadataResponse,
} from './types';
import { AppError, ErrorCodes, toAppError, type ApiErrorResponse } from './errors';
import { apiClient } from './utils/api';
import { getAuthTokens, saveAccessToken, clearAuthTokens } from './storage';

const API_BASE_URL = 'http://localhost:8080/api/v1';
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
  const defaultMessage = `Request failed with status ${response.status}`;

  if (body && typeof body === 'object') {
    const errorBody = body as ApiErrorResponse;
    if (errorBody.error) {
      return {
        code: errorBody.error.code || 'UNKNOWN_ERROR',
        message: errorBody.error.message || defaultMessage,
      };
    }
    // Legacy format
    const legacyBody = body as { code?: string; message?: string; error?: string };
    return {
      code: legacyBody.code || 'UNKNOWN_ERROR',
      message: legacyBody.message || legacyBody.error || defaultMessage,
    };
  }

  return { code: 'UNKNOWN_ERROR', message: defaultMessage };
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
    } as AddToLibraryResponse & { errorCode?: string };
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
      } as AddToLibraryResponse & { errorCode?: string };
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
    } as AddToLibraryResponse & { errorCode?: string };
  } catch (err) {
    markBackendReachable(false);
    const appError = toAppError(err);
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: appError.displayMessage,
      errorCode: appError.code,
    } as AddToLibraryResponse & { errorCode?: string };
  }
}

// Update track metadata via API
async function updateMetadata(
  message: UpdateMetadataMessage & { force?: boolean }
): Promise<UpdateMetadataResult> {
  // Check backend availability first
  const isAvailable = await checkBackendAvailability();
  if (!isAvailable) {
    return {
      type: 'UPDATE_METADATA_RESULT',
      success: false,
      error: 'Backend is currently unavailable. Please try again later.',
    };
  }

  const auth = await checkAuth();

  if (!auth.isLoggedIn || !auth.token) {
    return {
      type: 'UPDATE_METADATA_RESULT',
      success: false,
      error: 'not_logged_in',
    };
  }

  const requestBody: UpdateMetadataRequest & { force?: boolean } = {
    title: message.metadata.title,
    artist: message.metadata.artist,
    album: message.metadata.album,
    version: message.metadata.version,
    cover_art_url: message.metadata.cover_art_url,
  };

  // Include force flag if provided
  if (message.force) {
    requestBody.force = true;
  }

  try {
    const response = await apiClient.authorizedFetch(
      `/api/v1/tracks/${message.trackId}/metadata`,
      {
        method: 'PUT',
        body: JSON.stringify(requestBody),
      }
    );
    markBackendReachable(true);

    if (response.ok) {
      const data: UpdateMetadataResponse = await response.json();
      return {
        type: 'UPDATE_METADATA_RESULT',
        success: true,
        track: data.track,
        identityHashChanged: data.identity_hash_changed,
      };
    }

    // Parse error body
    const errorBody = await response.json().catch(() => undefined);
    const { code, message: errorMessage } = parseApiError(response, errorBody);

    // Handle specific error codes
    if (isAuthInvalidDueToTransientRefresh(response, code)) {
      return {
        type: 'UPDATE_METADATA_RESULT',
        success: false,
        error: TRANSIENT_REFRESH_ERROR,
      };
    }

    if (await clearAuthTokensForInvalidSession(response, code)) {
      return {
        type: 'UPDATE_METADATA_RESULT',
        success: false,
        error: 'not_logged_in',
      };
    }

    if (response.status === 409 || code === ErrorCodes.CONFLICT) {
      // Duplicate found
      const typedBody = errorBody as UpdateMetadataResponse | undefined;
      return {
        type: 'UPDATE_METADATA_RESULT',
        success: false,
        duplicateFound: true,
        duplicateTrackId: typedBody?.duplicate_track_id,
        error: 'duplicate_found',
      };
    }

    if (response.status === 404 || code === ErrorCodes.NOT_FOUND) {
      return {
        type: 'UPDATE_METADATA_RESULT',
        success: false,
        error: 'Track not found',
      };
    }

    return {
      type: 'UPDATE_METADATA_RESULT',
      success: false,
      error: errorMessage,
    };
  } catch (err) {
    markBackendReachable(false);
    const appError = toAppError(err);
    return {
      type: 'UPDATE_METADATA_RESULT',
      success: false,
      error: appError.displayMessage,
    };
  }
}

// Merge tracks via API
async function mergeTracks(
  sourceTrackId: string,
  targetTrackId: string
): Promise<{ success: boolean; error?: string }> {
  // Check backend availability first
  const isAvailable = await checkBackendAvailability();
  if (!isAvailable) {
    return {
      success: false,
      error: 'Backend is currently unavailable. Please try again later.',
    };
  }

  const auth = await checkAuth();

  if (!auth.isLoggedIn || !auth.token) {
    return {
      success: false,
      error: 'not_logged_in',
    };
  }

  try {
    const response = await apiClient.authorizedFetch(
      `/api/v1/tracks/${targetTrackId}/merge`,
      {
        method: 'POST',
        body: JSON.stringify({ source_track_id: sourceTrackId }),
      }
    );
    markBackendReachable(true);

    if (response.ok) {
      return { success: true };
    }

    // Parse error body
    const errorBody = await response.json().catch(() => undefined);
    const { code, message: errorMessage } = parseApiError(response, errorBody);

    if (isAuthInvalidDueToTransientRefresh(response, code)) {
      return {
        success: false,
        error: TRANSIENT_REFRESH_ERROR,
      };
    }

    if (await clearAuthTokensForInvalidSession(response, code)) {
      return {
        success: false,
        error: 'not_logged_in',
      };
    }

    return {
      success: false,
      error: errorMessage,
    };
  } catch (err) {
    markBackendReachable(false);
    const appError = toAppError(err);
    return {
      success: false,
      error: appError.displayMessage,
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
  console.log('Open Music Player extension installed');

  // Create context menu item
  chrome.contextMenus.create({
    id: CONTEXT_MENU_ID,
    title: 'Add to Open Music Player',
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
    updateMetadata(message as UpdateMetadataMessage & { force?: boolean }).then(sendResponse);
    return true;
  }

  if (message.type === 'MERGE_TRACKS') {
    mergeTracks(message.sourceTrackId, message.targetTrackId).then(sendResponse);
    return true;
  }

  return false;
});
