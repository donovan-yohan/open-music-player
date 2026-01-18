// Service worker for Open Music Player extension
import type {
  AddToLibraryMessage,
  AddToLibraryResponse,
  DownloadRequest,
  DownloadResponse,
  MetadataResponse,
  AuthState,
} from './types';

const API_BASE_URL = 'http://localhost:8080/api/v1';
const CONTEXT_MENU_ID = 'add-to-omp';

// Storage keys
const AUTH_TOKEN_KEY = 'auth_token';

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
    const response = await fetch(`${API_BASE_URL}/downloads`, {
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

    // Handle specific error codes
    if (response.status === 401) {
      await clearAuthToken();
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: false,
        error: 'not_logged_in',
      };
    }

    if (response.status === 409) {
      return {
        type: 'ADD_TO_LIBRARY_RESULT',
        success: false,
        error: 'already_added',
      };
    }

    const errorData = await response.json().catch(() => ({}));
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: errorData.error || `Request failed with status ${response.status}`,
    };
  } catch (err) {
    return {
      type: 'ADD_TO_LIBRARY_RESULT',
      success: false,
      error: err instanceof Error ? err.message : 'Network error',
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

  return false;
});
