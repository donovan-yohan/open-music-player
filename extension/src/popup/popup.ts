import type {
  MetadataResponse,
  AddToLibraryMessage,
  AddToLibraryResponse,
  PageMetadata,
  SourceType,
} from '../types';
import { AppError, toAppError } from '../errors';
import { endpoints } from '../endpoints';
import { setupOfflineDetection, showOfflineBanner, getErrorIcon, getErrorTitle } from '../errors/ui';

interface UIElements {
  loading: HTMLElement;
  unsupported: HTMLElement;
  notLoggedIn: HTMLElement;
  trackPreview: HTMLElement;
  success: HTMLElement;
  error: HTMLElement;
  alreadyAdded: HTMLElement;
  offline: HTMLElement;
  thumbnail: HTMLImageElement;
  sourceBadge: HTMLElement;
  trackTitle: HTMLElement;
  trackArtist: HTMLElement;
  addBtn: HTMLButtonElement;
  loginBtn: HTMLButtonElement;
  retryBtn: HTMLButtonElement;
  errorMessage: HTMLElement;
  errorTitle: HTMLElement;
  errorIcon: HTMLElement;
  jobStatus: HTMLElement;
  // Edit modal elements
  editBtn: HTMLButtonElement;
  editExistingBtn: HTMLButtonElement;
  editModal: HTMLElement;
  editCloseBtn: HTMLButtonElement;
  editForm: HTMLFormElement;
  editTitle: HTMLInputElement;
  editArtist: HTMLInputElement;
  editAlbum: HTMLInputElement;
  editVersion: HTMLInputElement;
  editCoverArt: HTMLInputElement;
  editError: HTMLElement;
  duplicateWarning: HTMLElement;
  mergeBtn: HTMLButtonElement;
  keepSeparateBtn: HTMLButtonElement;
  editCancelBtn: HTMLButtonElement;
  editSaveBtn: HTMLButtonElement;
}

interface State {
  url: string;
  sourceType: SourceType;
  metadata: PageMetadata;
  isAdding: boolean;
  // A queued download is not a library track.
  jobId: string | null;
}

let elements: UIElements;
let state: State;

// Keep retry intent separate from whether a request is currently in flight.
let lastError: AppError | null = null;
let retryAction: 'addToLibrary' | null = null;
let offlineBanner: HTMLElement | null = null;
let cleanupOfflineDetection: (() => void) | null = null;

function getElements(): UIElements {
  return {
    loading: document.getElementById('loading')!,
    unsupported: document.getElementById('unsupported')!,
    notLoggedIn: document.getElementById('not-logged-in')!,
    trackPreview: document.getElementById('track-preview')!,
    success: document.getElementById('success')!,
    error: document.getElementById('error')!,
    alreadyAdded: document.getElementById('already-added')!,
    offline: document.getElementById('offline') ?? createOfflineElement(),
    thumbnail: document.getElementById('thumbnail') as HTMLImageElement,
    sourceBadge: document.getElementById('source-badge')!,
    trackTitle: document.getElementById('track-title')!,
    trackArtist: document.getElementById('track-artist')!,
    addBtn: document.getElementById('add-btn') as HTMLButtonElement,
    loginBtn: document.getElementById('login-btn') as HTMLButtonElement,
    retryBtn: document.getElementById('retry-btn') as HTMLButtonElement,
    errorMessage: document.getElementById('error-message')!,
    errorTitle: document.getElementById('error-title') ?? createErrorTitleElement(),
    errorIcon: document.getElementById('error-icon') ?? createErrorIconElement(),
    jobStatus: document.getElementById('job-status')!,
    // Edit modal elements
    editBtn: document.getElementById('edit-btn') as HTMLButtonElement,
    editExistingBtn: document.getElementById('edit-existing-btn') as HTMLButtonElement,
    editModal: document.getElementById('edit-modal')!,
    editCloseBtn: document.getElementById('edit-close-btn') as HTMLButtonElement,
    editForm: document.getElementById('edit-form') as HTMLFormElement,
    editTitle: document.getElementById('edit-title') as HTMLInputElement,
    editArtist: document.getElementById('edit-artist') as HTMLInputElement,
    editAlbum: document.getElementById('edit-album') as HTMLInputElement,
    editVersion: document.getElementById('edit-version') as HTMLInputElement,
    editCoverArt: document.getElementById('edit-cover-art') as HTMLInputElement,
    editError: document.getElementById('edit-error')!,
    duplicateWarning: document.getElementById('duplicate-warning')!,
    mergeBtn: document.getElementById('merge-btn') as HTMLButtonElement,
    keepSeparateBtn: document.getElementById('keep-separate-btn') as HTMLButtonElement,
    editCancelBtn: document.getElementById('edit-cancel-btn') as HTMLButtonElement,
    editSaveBtn: document.getElementById('edit-save-btn') as HTMLButtonElement,
  };
}

function createOfflineElement(): HTMLElement {
  const el = document.createElement('div');
  el.id = 'offline';
  el.className = 'section hidden';
  el.innerHTML = `
    <div class="icon">📴</div>
    <h2>No Connection</h2>
    <p>You appear to be offline. Please check your internet connection.</p>
    <button id="offline-retry-btn" class="btn btn-secondary">Check Connection</button>
  `;
  document.body.appendChild(el);
  return el;
}

function createErrorTitleElement(): HTMLElement {
  const el = document.createElement('h3');
  el.id = 'error-title';
  el.textContent = 'Error';
  const errorSection = document.getElementById('error');
  if (errorSection) {
    const message = errorSection.querySelector('#error-message');
    if (message) {
      message.parentNode?.insertBefore(el, message);
    }
  }
  return el;
}

function createErrorIconElement(): HTMLElement {
  const el = document.createElement('div');
  el.id = 'error-icon';
  el.className = 'icon';
  el.textContent = '⚠️';
  const errorSection = document.getElementById('error');
  if (errorSection) {
    errorSection.insertBefore(el, errorSection.firstChild);
  }
  return el;
}

function hideAll(): void {
  elements.loading.classList.add('hidden');
  elements.unsupported.classList.add('hidden');
  elements.notLoggedIn.classList.add('hidden');
  elements.trackPreview.classList.add('hidden');
  elements.success.classList.add('hidden');
  elements.error.classList.add('hidden');
  elements.alreadyAdded.classList.add('hidden');
  elements.editModal.classList.add('hidden');
  elements.offline.classList.add('hidden');
}

function showSection(section: HTMLElement): void {
  hideAll();
  section.classList.remove('hidden');
}

function showLoading(): void {
  showSection(elements.loading);
}

function showUnsupported(): void {
  showSection(elements.unsupported);
}

function showNotLoggedIn(): void {
  showSection(elements.notLoggedIn);
}

function showTrackPreview(): void {
  showSection(elements.trackPreview);

  // Update UI with metadata
  if (state.metadata.thumbnail) {
    elements.thumbnail.src = state.metadata.thumbnail;
    elements.thumbnail.onerror = () => {
      elements.thumbnail.src = '';
      elements.thumbnail.style.background = '#2a2a2a';
    };
  }

  elements.sourceBadge.textContent = state.sourceType === 'youtube' ? 'YouTube' : 'SoundCloud';
  elements.trackTitle.textContent = state.metadata.title || 'Unknown Title';
  elements.trackArtist.textContent = state.metadata.artist || '';

  // Reset button state
  setAddButtonLoading(false);
}

function showSuccess(jobId?: string): void {
  showSection(elements.success);
  const message = elements.success.querySelector('.message');
  if (message) message.textContent = 'Download queued. Follow its progress in the Sound Q app.';
  elements.jobStatus.textContent = jobId ? `Job ID: ${jobId}` : 'Download queued';
}

function showError(errorOrMessage: string | Error | AppError): void {
  showSection(elements.error);

  // Convert to AppError for consistent handling
  let appError: AppError;
  if (typeof errorOrMessage === 'string') {
    appError = toAppError(new Error(errorOrMessage));
  } else {
    appError = toAppError(errorOrMessage);
  }

  // Store for retry
  lastError = appError;
  retryAction = appError.isRetryable ? 'addToLibrary' : null;

  // Update error display
  elements.errorIcon.textContent = getErrorIcon(appError);
  elements.errorTitle.textContent = getErrorTitle(appError);
  elements.errorMessage.textContent = appError.displayMessage;

  // Show/hide retry button based on whether error is retryable
  if (appError.isRetryable) {
    elements.retryBtn.classList.remove('hidden');
  } else {
    elements.retryBtn.classList.add('hidden');
  }

  // Handle auth errors specially
  if (appError.isAuthError) {
    showNotLoggedIn();
  }
}

function showOffline(): void {
  showSection(elements.offline);
}

function showAlreadyAdded(): void {
  showSection(elements.alreadyAdded);
}

function setAddButtonLoading(isLoading: boolean): void {
  state.isAdding = isLoading;
  elements.addBtn.disabled = isLoading;

  const btnText = elements.addBtn.querySelector('.btn-text')!;
  const btnLoading = elements.addBtn.querySelector('.btn-loading')!;

  if (isLoading) {
    btnText.classList.add('hidden');
    btnLoading.classList.remove('hidden');
  } else {
    btnText.classList.remove('hidden');
    btnLoading.classList.add('hidden');
  }
}

async function getActiveTabId(): Promise<number | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

async function getPageMetadata(): Promise<MetadataResponse | null> {
  const tabId = await getActiveTabId();
  if (!tabId) return null;

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

async function addToLibrary(): Promise<void> {
  if (state.isAdding) return;

  lastError = null;
  retryAction = null;
  elements.retryBtn.classList.add('hidden');
  showTrackPreview();
  setAddButtonLoading(true);

  const message: AddToLibraryMessage = {
    type: 'ADD_TO_LIBRARY',
    url: state.url,
    sourceType: state.sourceType,
    metadata: state.metadata,
  };

  try {
    const response = await new Promise<AddToLibraryResponse>((resolve, reject) => {
      chrome.runtime.sendMessage(message, (response: AddToLibraryResponse) => {
        if (chrome.runtime.lastError) {
          reject(AppError.network(chrome.runtime.lastError.message));
        } else {
          resolve(response);
        }
      });
    });

    if (response.success) {
      state.jobId = response.jobId || null;
      showSuccess(response.jobId);
    } else if (response.error === 'already_added') {
      state.jobId = null;
      showAlreadyAdded();
    } else if (response.error === 'not_logged_in') {
      showNotLoggedIn();
    } else {
      const message = response.error || 'Failed to add to library';
      showError(response.errorCode ? new AppError({ code: response.errorCode, message }) : message);
    }
  } catch (err) {
    showError(err instanceof Error ? err : AppError.network('Network error'));
  } finally {
    setAddButtonLoading(false);
  }
}

function setupEventListeners(): void {
  elements.addBtn.addEventListener('click', addToLibrary);

  elements.retryBtn.addEventListener('click', async () => {
    if (state.isAdding || retryAction !== 'addToLibrary' || !lastError?.isRetryable) return;
    // Only an explicit user click may retry a failed mutation.
    await addToLibrary();
  });

  elements.loginBtn.addEventListener('click', () => {
    // Open the app login page in a new tab
    chrome.tabs.create({ url: endpoints.webLoginUrl });
  });

  // Offline retry button
  const offlineRetryBtn = document.getElementById('offline-retry-btn');
  if (offlineRetryBtn) {
    offlineRetryBtn.addEventListener('click', async () => {
      if (navigator.onLine) {
        // Re-initialize the popup
        await init();
      }
    });
  }

  // Legacy metadata/merge routes are not supported by the current backend.
  for (const button of [elements.editBtn, elements.editExistingBtn, elements.mergeBtn,
    elements.keepSeparateBtn, elements.editSaveBtn]) {
    button.disabled = true;
    button.title = 'Metadata editing and track merging are not supported by this extension.';
    button.textContent = 'Unavailable in extension';
  }
}

async function init(): Promise<void> {
  elements = getElements();
  lastError = null;
  retryAction = null;
  state = {
    url: '',
    sourceType: 'unknown',
    metadata: { title: '' },
    isAdding: false,
    jobId: null,
  };

  setupEventListeners();

  // Set up offline detection
  if (cleanupOfflineDetection) {
    cleanupOfflineDetection();
  }
  cleanupOfflineDetection = setupOfflineDetection(
    () => {
      // On offline
      if (offlineBanner) return;
      offlineBanner = showOfflineBanner(document.body);
    },
    () => {
      // On online
      if (offlineBanner) {
        offlineBanner.remove();
        offlineBanner = null;
      }
    }
  );

  // Check if offline at startup
  if (!navigator.onLine) {
    showOffline();
    return;
  }

  showLoading();

  // Get metadata from the current page
  const metadata = await getPageMetadata();

  if (!metadata || !metadata.supported) {
    showUnsupported();
    return;
  }

  // Update state
  state.url = metadata.url;
  state.sourceType = metadata.sourceType;
  state.metadata = metadata.metadata;

  // Check auth status
  const authResponse = await new Promise<{ isLoggedIn: boolean }>((resolve) => {
    chrome.runtime.sendMessage({ type: 'CHECK_AUTH' }, (response) => {
      if (chrome.runtime.lastError) {
        resolve({ isLoggedIn: true }); // Assume logged in if can't check
      } else {
        resolve(response || { isLoggedIn: true });
      }
    });
  });

  if (!authResponse.isLoggedIn) {
    showNotLoggedIn();
    return;
  }

  showTrackPreview();
}

document.addEventListener('DOMContentLoaded', init);
