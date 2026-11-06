import type { Configuration } from '@azure/msal-browser';

export const msalConfig: Configuration = {
  auth: {
    clientId: import.meta.env.VITE_AZURE_AD_CLIENT_ID || '',
    authority: `https://login.microsoftonline.com/${import.meta.env.VITE_AZURE_AD_TENANT_ID || 'common'}`,
    redirectUri: window.location.origin
  },
  cache: {
    cacheLocation: 'localStorage',
    storeAuthStateInCookie: false
  }
};

const configuredApiScope = import.meta.env.VITE_API_SCOPE?.trim() ?? '';
const validApiScopeFormat = /^(https:\/\/|api:\/\/)[^/\s<>]+\/[A-Za-z0-9._/-]+$/i.test(configuredApiScope)
  && !configuredApiScope.includes('...');

export const apiRequestScopes = {
  scopes: validApiScopeFormat ? [configuredApiScope] : []
};
