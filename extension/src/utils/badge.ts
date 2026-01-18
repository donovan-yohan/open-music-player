import { BadgeState } from './types';

const BADGE_COLORS: Record<BadgeState, string> = {
  disabled: '#9CA3AF',
  ready: '#10B981',
  added: '#3B82F6',
};

const BADGE_TEXT: Record<BadgeState, string> = {
  disabled: '',
  ready: '+',
  added: '\u2713',
};

export async function setBadgeState(tabId: number, state: BadgeState): Promise<void> {
  await chrome.action.setBadgeBackgroundColor({
    tabId,
    color: BADGE_COLORS[state],
  });

  await chrome.action.setBadgeText({
    tabId,
    text: BADGE_TEXT[state],
  });

  if (state === 'disabled') {
    await chrome.action.setIcon({
      tabId,
      path: {
        16: 'icons/icon16-disabled.png',
        48: 'icons/icon48-disabled.png',
        128: 'icons/icon128-disabled.png',
      },
    }).catch(() => {
      // Fallback: disabled icons may not exist yet
    });
  } else {
    await chrome.action.setIcon({
      tabId,
      path: {
        16: 'icons/icon16.png',
        48: 'icons/icon48.png',
        128: 'icons/icon128.png',
      },
    }).catch(() => {
      // Fallback if icons don't exist
    });
  }
}

export async function clearBadge(tabId: number): Promise<void> {
  await chrome.action.setBadgeText({ tabId, text: '' });
}
