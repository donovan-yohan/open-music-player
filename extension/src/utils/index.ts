export function sendMessage<T>(message: unknown): Promise<T> {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (response: T) => {
      resolve(response);
    });
  });
}
