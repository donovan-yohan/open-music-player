export async function getStorageItem<T>(key: string): Promise<T | null> {
  return new Promise((resolve) => {
    chrome.storage.local.get([key], (result) => {
      resolve(result[key] ?? null);
    });
  });
}

export async function setStorageItem<T>(key: string, value: T): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [key]: value }, () => {
      resolve();
    });
  });
}

export async function removeStorageItem(key: string): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.remove([key], () => {
      resolve();
    });
  });
}
