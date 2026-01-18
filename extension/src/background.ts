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

const API_BASE_URL = 'http://localhost:8080/api/v1';
const CONTEXT_MENU_ID = 'add-to-omp';
const DEFAULT_TIMEOUT = 30000;
const MAX_RETRIES = 3;
const INITIAL_BACKOFF = 1000;

// Storage keys
const AUTH_TOKEN_KEY = 'auth_token';

// Backend availability state
let backendAvailable = true;
let lastBackendCheck = 0;
const BACKEND_CHECK_INTERVAL = 30000; // 30 seconds

// Calculate exponential backoff with jitter
function calculateBackoff(attempt: number): number {
  const maxBackoff = 30000;
  const backoff = Math.min(INITIAL_BACKOFF * Math.pow(2, attempt), maxBackoff);
  const jitter = backoff * 0.25 * (Math.random() * 2 - 1);
  return Math.floor(backoff + jitter);
}

// Sleep helper
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Fetch with timeout and retry
async function fetchWithRetry(
  url: string,
  options: RequestInit,
  maxRetries = MAX_RETRIES
): Promise<Response> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT);

    try {
      const response = await fetch(url, {
        ...options,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      // Update backend availability
      backendAvailable = true;
      lastBackendCheck = Date.now();

      // Don't retry client errors (4xx except 429)
      if (response.status >= 400 && response.status < 500 && response.status !== 429) {
        return response;
      }

      // Retry server errors (5xx) and rate limiting (429)
      if (response.status >= 500 || response.status === 429) {
        lastError = new Error(`Server error: ${response.status}`);
        if (attempt < maxRetries) {
          const backoff = calculateBackoff(attempt);
          console.log(`Retrying request in ${backoff}ms (attempt ${attempt + 1}/${maxRetries})`);
          await sleep(backoff);
          continue;
        }
      }

      return response;
    } catch (err) {
      clearTimeout(timeoutId);

      if (err instanceof DOMException && err.name === 'AbortError') {
        lastError = new Error('Request timed out');
      } else {
        lastError = err instanceof Error ? err : new Error(String(err));
        // Mark backend as potentially unavailable
        backendAvailable = false;
        lastBackendCheck = Date.now();
      }

      if (attempt < maxRetries) {
        const backoff = calculateBackoff(attempt);
        console.log(`Retrying after error in ${backoff}ms (attempt ${attempt + 1}/${maxRetries})`);
        await sleep(backoff);
        continue;
      }
    }
  }

  throw lastError ?? new Error('Request failed after all retries');
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

// Get auth token from storage
async function getAuthToken(): Promise<string | null> {
  const result = await chrome.storage.local.get(AUTH_TOKEN_KEY);
  return result[AUTH_TOKEN_KEY] || null;
}

// Set auth token in storage
async function setAuthToken(token: string): Promise<void> {
  await chrome.storage.local.set({ [AUTH_TOKEN_KEY]: token });
}

// Clear auth token from storage
async function clearAuthToken(): Promise<void> {
  await chrome.storage.local.remove(AUTH_TOKEN_KEY);
}

// Check if user is logged in
async function checkAuth(): Promise<AuthState> {
  const token = await getAuthToken();
  if (!token) {
    return { isLoggedIn: false };
  }

  // Optionally validate token with backend
  try {
    const response = await fetch(`${API_BASE_URL}/auth/validate`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${token}`,
      },
    });

    if (response.ok) {
      return { isLoggedIn: true, token };
    } else {
      // Token invalid, clear it
      await clearAuthToken();
      return { isLoggedIn: false };
    }
  } catch {
    // Network error, assume logged in if we have a token
    return { isLoggedIn: true, token };
  }
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
    const response = await fetchWithRetry(`${API_BASE_URL}/downloads`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${auth.token}`,
      },
      body: JSON.stringify(requestBody),
    });

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
    if (response.status === 401 || code === ErrorCodes.UNAUTHORIZED || code === ErrorCodes.INVALID_TOKEN) {
      await clearAuthToken();
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
    const response = await fetchWithRetry(`${API_BASE_URL}/tracks/${message.trackId}/metadata`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${auth.token}`,
      },
      body: JSON.stringify(requestBody),
    });

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
    if (response.status === 401 || code === ErrorCodes.UNAUTHORIZED) {
      await clearAuthToken();
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
    const response = await fetchWithRetry(`${API_BASE_URL}/tracks/${targetTrackId}/merge`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${auth.token}`,
      },
      body: JSON.stringify({ source_track_id: sourceTrackId }),
    });

    if (response.ok) {
      return { success: true };
    }

    // Parse error body
    const errorBody = await response.json().catch(() => undefined);
    const { code, message: errorMessage } = parseApiError(response, errorBody);

    if (response.status === 401 || code === ErrorCodes.UNAUTHORIZED) {
      await clearAuthToken();
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
    setAuthToken(message.token).then(() => {
      sendResponse({ success: true });
    });
    return true;
  }

  if (message.type === 'LOGOUT') {
    clearAuthToken().then(() => {
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
