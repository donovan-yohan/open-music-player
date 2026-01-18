import type { DownloadJobState, WebSocketState, GetDownloadStateResponse, ProgressUpdateMessage, GetAuthStateResponse } from '../types';

// DOM Elements
let statusDot: HTMLElement | null;
let statusText: HTMLElement | null;
let authSection: HTMLElement | null;
let mainContent: HTMLElement | null;
let downloadsList: HTMLElement | null;
let backendUnavailable: HTMLElement | null;
let retryBtn: HTMLElement | null;

// Current state
let currentJobs: DownloadJobState[] = [];
let currentWsState: WebSocketState = 'disconnected';
let isAuthenticated = false;

document.addEventListener('DOMContentLoaded', () => {
  initializeElements();
  setupEventListeners();
  setupMessageListener();
  loadInitialState();
});

function initializeElements(): void {
  statusDot = document.getElementById('statusDot');
  statusText = document.getElementById('statusText');
  authSection = document.getElementById('authSection');
  mainContent = document.getElementById('mainContent');
  downloadsList = document.getElementById('downloadsList');
  backendUnavailable = document.getElementById('backendUnavailable');
  retryBtn = document.getElementById('retryBtn');
}

function setupEventListeners(): void {
  retryBtn?.addEventListener('click', () => {
    chrome.runtime.sendMessage({ type: 'RECONNECT_WS' });
    updateConnectionStatus('connecting');
  });

  document.getElementById('signInLink')?.addEventListener('click', (e) => {
    e.preventDefault();
    // Open the main app for sign in
    chrome.tabs.create({ url: 'http://localhost:8080' });
  });
}

function setupMessageListener(): void {
  chrome.runtime.onMessage.addListener((message) => {
    if (message.type === 'PROGRESS_UPDATE') {
      const progressMessage = message as ProgressUpdateMessage;
      updateJobInList(progressMessage.job);
    } else if (message.type === 'WS_STATE_CHANGE') {
      updateConnectionStatus(message.state);
    }
  });
}

async function loadInitialState(): Promise<void> {
  // Check auth state
  const authResponse = await sendMessage({ type: 'GET_AUTH_STATE' }) as GetAuthStateResponse | null;
  isAuthenticated = authResponse?.isAuthenticated ?? false;

  if (!isAuthenticated) {
    showAuthSection();
    return;
  }

  showMainContent();

  // Get current download state
  const stateResponse = await sendMessage({ type: 'GET_DOWNLOAD_STATE' }) as GetDownloadStateResponse;
  if (stateResponse) {
    currentJobs = stateResponse.jobs;
    currentWsState = stateResponse.wsState;
    renderDownloadsList();
    updateConnectionStatus(currentWsState);
  }
}

function showAuthSection(): void {
  if (authSection) authSection.style.display = 'block';
  if (mainContent) mainContent.style.display = 'none';
  updateConnectionStatus('disconnected');
}

function showMainContent(): void {
  if (authSection) authSection.style.display = 'none';
  if (mainContent) mainContent.style.display = 'block';
}

function updateConnectionStatus(state: WebSocketState): void {
  currentWsState = state;

  if (statusDot) {
    statusDot.className = `status-dot ${state}`;
  }

  if (statusText) {
    const statusLabels: Record<WebSocketState, string> = {
      connected: 'Connected',
      connecting: 'Connecting...',
      reconnecting: 'Reconnecting...',
      disconnected: 'Disconnected',
    };
    statusText.textContent = statusLabels[state];
  }

  // Show/hide backend unavailable message
  if (backendUnavailable) {
    backendUnavailable.style.display = state === 'disconnected' && isAuthenticated ? 'block' : 'none';
  }
}

function updateJobInList(job: DownloadJobState): void {
  const existingIndex = currentJobs.findIndex((j) => j.jobId === job.jobId);

  if (existingIndex >= 0) {
    currentJobs[existingIndex] = job;
  } else {
    currentJobs.unshift(job);
  }

  // Remove completed/failed jobs after 5 seconds (handled by background, but also clean up locally)
  if (job.status === 'completed' || job.status === 'failed') {
    setTimeout(() => {
      currentJobs = currentJobs.filter((j) => j.jobId !== job.jobId);
      renderDownloadsList();
    }, 5000);
  }

  renderDownloadsList();
}

function renderDownloadsList(): void {
  if (!downloadsList) return;

  if (currentJobs.length === 0) {
    downloadsList.innerHTML = `
      <div class="empty-state">
        <div class="empty-state-icon">🎵</div>
        <p>No active downloads</p>
      </div>
    `;
    return;
  }

  downloadsList.innerHTML = currentJobs.map((job) => renderJobCard(job)).join('');
}

function renderJobCard(job: DownloadJobState): string {
  const statusLabels: Record<string, string> = {
    pending: 'Queued',
    downloading: 'Downloading',
    processing: 'Processing',
    completed: 'Added!',
    failed: 'Failed',
  };

  let progressSection = '';

  if (job.status === 'downloading' || job.status === 'processing') {
    progressSection = `
      <div class="progress-container">
        <div class="progress-bar">
          <div class="progress-fill" style="width: ${job.progress}%"></div>
        </div>
        <div class="progress-text">
          <span>${statusLabels[job.status]}</span>
          <span>${job.progress}%</span>
        </div>
      </div>
    `;
  } else if (job.status === 'completed') {
    progressSection = `
      <div class="job-completed">
        <span class="checkmark">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
            <polyline points="20 6 9 17 4 12"></polyline>
          </svg>
        </span>
        <span>Added to library</span>
      </div>
    `;
  } else if (job.status === 'failed' && job.error) {
    progressSection = `
      <div class="job-error">${escapeHtml(job.error)}</div>
    `;
  } else if (job.status === 'pending') {
    progressSection = `
      <div class="progress-container">
        <div class="progress-bar">
          <div class="progress-fill" style="width: 0%"></div>
        </div>
        <div class="progress-text">
          <span>Waiting...</span>
          <span>—</span>
        </div>
      </div>
    `;
  }

  return `
    <div class="download-job">
      <div class="job-header">
        <div class="job-info">
          <div class="job-title">${escapeHtml(job.trackTitle)}</div>
          <div class="job-artist">${escapeHtml(job.artistName)}</div>
        </div>
        <span class="job-status ${job.status}">${statusLabels[job.status]}</span>
      </div>
      ${progressSection}
    </div>
  `;
}

function escapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function sendMessage(message: { type: string; payload?: unknown }): Promise<unknown> {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (response) => {
      resolve(response);
    });
  });
}
