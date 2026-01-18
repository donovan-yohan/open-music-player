import type { MetadataResponse, AddToLibraryMessage, AddToLibraryResponse, PageMetadata, SourceType } from '../types';

interface UIElements {
  loading: HTMLElement;
  unsupported: HTMLElement;
  notLoggedIn: HTMLElement;
  trackPreview: HTMLElement;
  success: HTMLElement;
  error: HTMLElement;
  alreadyAdded: HTMLElement;
  thumbnail: HTMLImageElement;
  sourceBadge: HTMLElement;
  trackTitle: HTMLElement;
  trackArtist: HTMLElement;
  addBtn: HTMLButtonElement;
  loginBtn: HTMLButtonElement;
  retryBtn: HTMLButtonElement;
  errorMessage: HTMLElement;
  jobStatus: HTMLElement;
}

interface State {
  url: string;
  sourceType: SourceType;
  metadata: PageMetadata;
  isAdding: boolean;
}

let elements: UIElements;
let state: State;

function getElements(): UIElements {
  return {
    loading: document.getElementById('loading')!,
    unsupported: document.getElementById('unsupported')!,
    notLoggedIn: document.getElementById('not-logged-in')!,
    trackPreview: document.getElementById('track-preview')!,
    success: document.getElementById('success')!,
    error: document.getElementById('error')!,
    alreadyAdded: document.getElementById('already-added')!,
    thumbnail: document.getElementById('thumbnail') as HTMLImageElement,
    sourceBadge: document.getElementById('source-badge')!,
    trackTitle: document.getElementById('track-title')!,
    trackArtist: document.getElementById('track-artist')!,
    addBtn: document.getElementById('add-btn') as HTMLButtonElement,
    loginBtn: document.getElementById('login-btn') as HTMLButtonElement,
    retryBtn: document.getElementById('retry-btn') as HTMLButtonElement,
    errorMessage: document.getElementById('error-message')!,
    jobStatus: document.getElementById('job-status')!,
  };
}

function hideAll(): void {
  elements.loading.classList.add('hidden');
  elements.unsupported.classList.add('hidden');
  elements.notLoggedIn.classList.add('hidden');
  elements.trackPreview.classList.add('hidden');
  elements.success.classList.add('hidden');
  elements.error.classList.add('hidden');
  elements.alreadyAdded.classList.add('hidden');
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

function showError(message: string): void {
  showSection(elements.error);
  elements.errorMessage.textContent = message;
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
      showSuccess(response.jobId);
    } else if (response.error === 'already_added') {
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

function setupEventListeners(): void {
  elements.addBtn.addEventListener('click', addToLibrary);

  elements.retryBtn.addEventListener('click', () => {
    showTrackPreview();
  });

  elements.loginBtn.addEventListener('click', () => {
    // Open the app login page in a new tab
    chrome.tabs.create({ url: 'http://localhost:8080/login' });
  });
}

async function init(): Promise<void> {
  elements = getElements();
  state = {
    url: '',
    sourceType: 'unknown',
    metadata: { title: '' },
    isAdding: false,
  };

  setupEventListeners();
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
