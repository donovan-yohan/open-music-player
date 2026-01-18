chrome.runtime.onInstalled.addListener(() => {
  console.log('Open Music Player extension installed');
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'PING') {
    sendResponse({ type: 'PONG' });
  }
  return true;
});
