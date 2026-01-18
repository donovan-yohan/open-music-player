const API_BASE_URL = 'http://localhost:8080';

export async function fetchApi<T>(
  endpoint: string,
  options?: RequestInit
): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${endpoint}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (!response.ok) {
    throw new Error(`API error: ${response.status}`);
  }

  return response.json();
}

export function sendMessage<T>(message: unknown): Promise<T> {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (response: T) => {
      resolve(response);
    });
  });
}
