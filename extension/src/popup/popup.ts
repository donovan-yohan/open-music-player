import type {
  MetadataResponse,
  AddToLibraryMessage,
  AddToLibraryResponse,
  PageMetadata,
  SourceType,
  UpdateMetadataMessage,
  UpdateMetadataResult,
  TrackMetadata,
} from '../types';
import { toAppError, type AppError } from '../errors';
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
  // Edit state
  trackId: string | null;
  isEditing: boolean;
  duplicateTrackId: string | null;
}

let elements: UIElements;
let state: State;

// Track last error for retry
let lastError: AppError | null = null;
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
  if (jobId) {
    elements.jobStatus.textContent = `Job ID: ${jobId}`;
  }
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

function showEditModal(): void {
  hideAll();
  elements.editModal.classList.remove('hidden');

  // Pre-fill form with current metadata
  elements.editTitle.value = state.metadata.title || '';
  elements.editArtist.value = state.metadata.artist || '';
  elements.editAlbum.value = '';
  elements.editVersion.value = '';
  elements.editCoverArt.value = state.metadata.thumbnail || '';

  // Reset error and warning states
  elements.editError.classList.add('hidden');
  elements.editError.textContent = '';
  elements.duplicateWarning.classList.add('hidden');
  state.duplicateTrackId = null;

  // Reset save button state
  setEditSaveButtonLoading(false);
}

function hideEditModal(): void {
  elements.editModal.classList.add('hidden');
  // Return to the appropriate previous state
  if (state.trackId) {
    showSuccess(state.trackId);
  } else {
    showTrackPreview();
  }
}

function showEditError(message: string): void {
  elements.editError.textContent = message;
  elements.editError.classList.remove('hidden');
}

function hideEditError(): void {
  elements.editError.classList.add('hidden');
  elements.editError.textContent = '';
}

function showDuplicateWarning(duplicateTrackId: string): void {
  state.duplicateTrackId = duplicateTrackId;
  elements.duplicateWarning.classList.remove('hidden');
}

function hideDuplicateWarning(): void {
  elements.duplicateWarning.classList.add('hidden');
  state.duplicateTrackId = null;
}

function setEditSaveButtonLoading(isLoading: boolean): void {
  state.isEditing = isLoading;
  elements.editSaveBtn.disabled = isLoading;

  const btnText = elements.editSaveBtn.querySelector('.btn-text')!;
  const btnLoading = elements.editSaveBtn.querySelector('.btn-loading')!;

  if (isLoading) {
    btnText.classList.add('hidden');
    btnLoading.classList.remove('hidden');
  } else {
    btnText.classList.remove('hidden');
    btnLoading.classList.add('hidden');
  }
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
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(response);
        }
      });
    });

    if (response.success) {
      state.trackId = response.jobId || null;
      showSuccess(response.jobId);
    } else if (response.error === 'already_added') {
      // Store track ID from error response if available
      state.trackId = response.jobId || null;
      showAlreadyAdded();
    } else if (response.error === 'not_logged_in') {
      showNotLoggedIn();
    } else {
      showError(response.error || 'Failed to add to library');
    }
  } catch (err) {
    showError(err instanceof Error ? err.message : 'Network error');
  }
}

async function saveMetadata(forceSave = false): Promise<void> {
  if (state.isEditing) return;
  if (!state.trackId) {
    showEditError('No track to edit');
    return;
  }

  // Validate required fields
  const title = elements.editTitle.value.trim();
  const artist = elements.editArtist.value.trim();

  if (!title) {
    showEditError('Title is required');
    return;
  }

  if (!artist) {
    showEditError('Artist is required');
    return;
  }

  hideEditError();
  hideDuplicateWarning();
  setEditSaveButtonLoading(true);

  const message: UpdateMetadataMessage = {
    type: 'UPDATE_METADATA',
    trackId: state.trackId,
    metadata: {
      title,
      artist,
      album: elements.editAlbum.value.trim() || undefined,
      version: elements.editVersion.value.trim() || undefined,
      cover_art_url: elements.editCoverArt.value.trim() || undefined,
    },
  };

  // Add force flag if user confirmed to keep separate
  if (forceSave) {
    (message as UpdateMetadataMessage & { force: boolean }).force = true;
  }

  try {
    const response = await new Promise<UpdateMetadataResult>((resolve, reject) => {
      chrome.runtime.sendMessage(message, (response: UpdateMetadataResult) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(response);
        }
      });
    });

    setEditSaveButtonLoading(false);

    if (response.success) {
      // Update local metadata state with new values
      if (response.track) {
        state.metadata.title = response.track.title;
        state.metadata.artist = response.track.artist;
      }
      // Show success and return to success view
      hideEditModal();
    } else if (response.duplicateFound && response.duplicateTrackId) {
      // Show duplicate warning with merge option
      showDuplicateWarning(response.duplicateTrackId);
    } else {
      showEditError(response.error || 'Failed to update metadata');
    }
  } catch (err) {
    setEditSaveButtonLoading(false);
    showEditError(err instanceof Error ? err.message : 'Network error');
  }
}

async function mergeWithDuplicate(): Promise<void> {
  if (!state.trackId || !state.duplicateTrackId) {
    showEditError('Cannot merge tracks');
    return;
  }

  setEditSaveButtonLoading(true);
  hideDuplicateWarning();

  const message = {
    type: 'MERGE_TRACKS',
    sourceTrackId: state.trackId,
    targetTrackId: state.duplicateTrackId,
  };

  try {
    const response = await new Promise<{ success: boolean; error?: string }>((resolve, reject) => {
      chrome.runtime.sendMessage(message, (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(response);
        }
      });
    });

    setEditSaveButtonLoading(false);

    if (response.success) {
      // Track was merged, return to library view
      hideEditModal();
    } else {
      showEditError(response.error || 'Failed to merge tracks');
    }
  } catch (err) {
    setEditSaveButtonLoading(false);
    showEditError(err instanceof Error ? err.message : 'Network error');
  }
}

function setupEventListeners(): void {
  elements.addBtn.addEventListener('click', addToLibrary);

  elements.retryBtn.addEventListener('click', async () => {
    // Retry the last operation based on state
    if (lastError) {
      if (state.isAdding) {
        await addToLibrary();
      } else {
        showTrackPreview();
      }
    } else {
      showTrackPreview();
    }
  });

  elements.loginBtn.addEventListener('click', () => {
    // Open the app login page in a new tab
    chrome.tabs.create({ url: 'http://localhost:8080/login' });
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

  // Edit modal event listeners
  elements.editBtn.addEventListener('click', showEditModal);
  elements.editExistingBtn.addEventListener('click', showEditModal);
  elements.editCloseBtn.addEventListener('click', hideEditModal);
  elements.editCancelBtn.addEventListener('click', hideEditModal);

  // Form submission
  elements.editForm.addEventListener('submit', (e) => {
    e.preventDefault();
    saveMetadata();
  });

  // Duplicate handling
  elements.mergeBtn.addEventListener('click', mergeWithDuplicate);
  elements.keepSeparateBtn.addEventListener('click', () => {
    // Save with force flag to skip duplicate check
    saveMetadata(true);
  });
}

async function init(): Promise<void> {
  elements = getElements();
  state = {
    url: '',
    sourceType: 'unknown',
    metadata: { title: '' },
    isAdding: false,
    trackId: null,
    isEditing: false,
    duplicateTrackId: null,
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
