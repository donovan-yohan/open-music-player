import type { DownloadJobState } from '../types';
import { getNotificationsEnabled } from '../storage';

const NOTIFICATION_ICONS = {
  success: 'icons/icon128.png',
  error: 'icons/icon128.png',
};

export async function showDownloadCompleteNotification(job: DownloadJobState): Promise<void> {
  const enabled = await getNotificationsEnabled();
  if (!enabled) return;

  const notificationId = `download-complete-${job.jobId}`;

  chrome.notifications.create(notificationId, {
    type: 'basic',
    iconUrl: NOTIFICATION_ICONS.success,
    title: 'Download Complete',
    message: `${job.trackTitle} by ${job.artistName} has been added to your library.`,
    priority: 1,
  });

  // Auto-close after 5 seconds
  setTimeout(() => {
    chrome.notifications.clear(notificationId);
  }, 5000);
}

export async function showDownloadErrorNotification(job: DownloadJobState): Promise<void> {
  const enabled = await getNotificationsEnabled();
  if (!enabled) return;

  const notificationId = `download-error-${job.jobId}`;

  chrome.notifications.create(notificationId, {
    type: 'basic',
    iconUrl: NOTIFICATION_ICONS.error,
    title: 'Download Failed',
    message: job.error || `Failed to download ${job.trackTitle}.`,
    priority: 2,
  });

  // Auto-close after 8 seconds
  setTimeout(() => {
    chrome.notifications.clear(notificationId);
  }, 8000);
}

export function setupNotificationHandlers(): void {
  // Handle notification clicks
  chrome.notifications.onClicked.addListener((notificationId) => {
    // Clear the notification when clicked
    chrome.notifications.clear(notificationId);

    // Could open the popup or a specific page here
    // For now, just clear the notification
  });

  // Handle notification button clicks (if we add buttons later)
  chrome.notifications.onButtonClicked.addListener((notificationId, buttonIndex) => {
    chrome.notifications.clear(notificationId);
  });
}
