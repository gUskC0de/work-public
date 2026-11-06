import axios from 'axios';
import type { InteractionRequiredAuthError, PublicClientApplication } from '@azure/msal-browser';
import { apiRequestScopes } from '../auth/authConfig';

export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api'
});

/**
 * Wires the axios instance to acquire (and silently refresh) an Entra ID access token
 * before every request. Called once from main.tsx after MSAL initializes.
 */
export function attachAuthInterceptor(msalInstance: PublicClientApplication) {
  apiClient.interceptors.request.use(async (config) => {
    const account = msalInstance.getActiveAccount() ?? msalInstance.getAllAccounts()[0];
    if (!account) {
      return config;
    }

    try {
      const result = await msalInstance.acquireTokenSilent({ ...apiRequestScopes, account });
      config.headers.Authorization = `Bearer ${result.accessToken}`;
    } catch (error) {
      const interactionError = error as InteractionRequiredAuthError;
      await msalInstance.acquireTokenRedirect({ ...apiRequestScopes, account });
      throw interactionError;
    }

    return config;
  });
}
