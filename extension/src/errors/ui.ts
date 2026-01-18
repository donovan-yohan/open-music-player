/**
 * UI utilities for error display in the Chrome Extension
 */

import { AppError, ErrorCodes, toAppError } from './index';

/** Error display configuration */
export interface ErrorDisplayConfig {
  container: HTMLElement;
  messageElement?: HTMLElement;
  retryButton?: HTMLButtonElement;
  onRetry?: () => Promise<void> | void;
}

/** Update error display in the UI */
export function showError(config: ErrorDisplayConfig, error: unknown): void {
  const appError = toAppError(error);
  const { container, messageElement, retryButton, onRetry } = config;

  // Show the error container
  container.classList.remove('hidden');

  // Update message text
  if (messageElement) {
    messageElement.textContent = appError.displayMessage;
  }

  // Show/hide retry button based on whether error is retryable
  if (retryButton) {
    if (appError.isRetryable && onRetry) {
      retryButton.classList.remove('hidden');
      // Clear existing listeners
      const newButton = retryButton.cloneNode(true) as HTMLButtonElement;
      retryButton.parentNode?.replaceChild(newButton, retryButton);
      newButton.addEventListener('click', async () => {
        newButton.disabled = true;
        try {
          await onRetry();
        } finally {
          newButton.disabled = false;
        }
      });
    } else {
      retryButton.classList.add('hidden');
    }
  }
}

/** Hide error display */
export function hideError(container: HTMLElement): void {
  container.classList.add('hidden');
}

/** Create an error banner element */
export function createErrorBanner(error: unknown, onRetry?: () => void): HTMLElement {
  const appError = toAppError(error);

  const banner = document.createElement('div');
  banner.className = 'error-banner';
  banner.style.cssText = `
    background-color: #fee2e2;
    border: 1px solid #fecaca;
    border-radius: 8px;
    padding: 12px 16px;
    margin: 8px 0;
    display: flex;
    align-items: center;
    gap: 12px;
  `;

  // Error icon
  const icon = document.createElement('span');
  icon.innerHTML = '⚠️';
  icon.style.flexShrink = '0';

  // Message text
  const message = document.createElement('span');
  message.textContent = appError.displayMessage;
  message.style.cssText = `
    flex: 1;
    color: #991b1b;
    font-size: 14px;
  `;

  banner.appendChild(icon);
  banner.appendChild(message);

  // Retry button if error is retryable
  if (appError.isRetryable && onRetry) {
    const retryBtn = document.createElement('button');
    retryBtn.textContent = 'Retry';
    retryBtn.style.cssText = `
      background: #dc2626;
      color: white;
      border: none;
      border-radius: 4px;
      padding: 6px 12px;
      cursor: pointer;
      font-size: 12px;
    `;
    retryBtn.addEventListener('click', onRetry);
    banner.appendChild(retryBtn);
  }

  return banner;
}

/** Get icon for error category */
export function getErrorIcon(error: AppError): string {
  switch (error.category) {
    case 'network':
      return error.code === ErrorCodes.OFFLINE ? '📴' : '🌐';
    case 'server':
      return '🖥️';
    case 'external':
      return '☁️';
    case 'client':
      return error.isAuthError ? '🔐' : '⚠️';
    default:
      return '⚠️';
  }
}

/** Get title for error category */
export function getErrorTitle(error: AppError): string {
  switch (error.category) {
    case 'network':
      return error.code === ErrorCodes.OFFLINE ? 'No Connection' : 'Connection Error';
    case 'server':
      return 'Server Error';
    case 'external':
      return 'Service Unavailable';
    case 'client':
      return error.isAuthError ? 'Session Expired' : 'Error';
    default:
      return 'Error';
  }
}

/** Show offline banner */
export function showOfflineBanner(container: HTMLElement): HTMLElement {
  const banner = document.createElement('div');
  banner.className = 'offline-banner';
  banner.style.cssText = `
    background-color: #fef3c7;
    border-bottom: 1px solid #fcd34d;
    padding: 8px 16px;
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: #92400e;
  `;

  const icon = document.createElement('span');
  icon.textContent = '📴';

  const text = document.createElement('span');
  text.textContent = "You're offline. Some features may be unavailable.";
  text.style.flex = '1';

  const retryBtn = document.createElement('button');
  retryBtn.textContent = 'Check';
  retryBtn.style.cssText = `
    background: transparent;
    color: #92400e;
    border: 1px solid #92400e;
    border-radius: 4px;
    padding: 4px 8px;
    cursor: pointer;
    font-size: 12px;
  `;
  retryBtn.addEventListener('click', async () => {
    if (navigator.onLine) {
      banner.remove();
      // Trigger reconnection logic
      window.dispatchEvent(new CustomEvent('online-check'));
    }
  });

  banner.appendChild(icon);
  banner.appendChild(text);
  banner.appendChild(retryBtn);

  container.insertBefore(banner, container.firstChild);
  return banner;
}

/** Set up offline detection */
export function setupOfflineDetection(
  onOffline: () => void,
  onOnline: () => void
): () => void {
  const handleOffline = () => onOffline();
  const handleOnline = () => onOnline();

  window.addEventListener('offline', handleOffline);
  window.addEventListener('online', handleOnline);

  // Initial check
  if (!navigator.onLine) {
    onOffline();
  }

  // Cleanup function
  return () => {
    window.removeEventListener('offline', handleOffline);
    window.removeEventListener('online', handleOnline);
  };
}

/** Loading state helper */
export function setLoading(
  button: HTMLButtonElement,
  isLoading: boolean,
  loadingText = 'Loading...'
): void {
  const textEl = button.querySelector('.btn-text') as HTMLElement | null;
  const loadingEl = button.querySelector('.btn-loading') as HTMLElement | null;

  if (textEl && loadingEl) {
    if (isLoading) {
      textEl.classList.add('hidden');
      loadingEl.classList.remove('hidden');
    } else {
      textEl.classList.remove('hidden');
      loadingEl.classList.add('hidden');
    }
  } else {
    // Simple button without separate elements
    if (isLoading) {
      button.dataset.originalText = button.textContent ?? '';
      button.textContent = loadingText;
    } else if (button.dataset.originalText) {
      button.textContent = button.dataset.originalText;
    }
  }

  button.disabled = isLoading;
}

/** Execute with error handling */
export async function withErrorHandling<T>(
  operation: () => Promise<T>,
  options: {
    onError?: (error: AppError) => void;
    onAuthError?: () => void;
    showErrorUI?: ErrorDisplayConfig;
    rethrow?: boolean;
  }
): Promise<T | null> {
  try {
    const result = await operation();
    if (options.showErrorUI) {
      hideError(options.showErrorUI.container);
    }
    return result;
  } catch (error) {
    const appError = toAppError(error);

    // Handle auth errors specially
    if (appError.isAuthError && options.onAuthError) {
      options.onAuthError();
    }

    // Show error in UI
    if (options.showErrorUI) {
      showError(options.showErrorUI, appError);
    }

    // Call error callback
    if (options.onError) {
      options.onError(appError);
    }

    // Optionally rethrow
    if (options.rethrow) {
      throw appError;
    }

    return null;
  }
}
