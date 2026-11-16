import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { PublicClientApplication, EventType } from '@azure/msal-browser';
import { MsalProvider } from '@azure/msal-react';
import { msalConfig } from './auth/authConfig';
import { attachAuthInterceptor } from './api/client';
import { AppThemeProvider } from './theme/AppThemeProvider';
import { App } from './App';
import { isDeveloperMode } from './auth/developerMode';

const root = createRoot(document.getElementById('root')!);
const app = (
  <AppThemeProvider>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </AppThemeProvider>
);

if (isDeveloperMode) {
  root.render(<StrictMode>{app}</StrictMode>);
} else {
  const msalInstance = new PublicClientApplication(msalConfig);

  msalInstance.addEventCallback((event) => {
    if (event.eventType === EventType.LOGIN_SUCCESS && event.payload) {
      const payload = event.payload as { account?: unknown };
      if (payload.account) {
        msalInstance.setActiveAccount(payload.account as never);
      }
    }
  });

  attachAuthInterceptor(msalInstance);

  msalInstance.initialize().then(() => {
    const existingAccounts = msalInstance.getAllAccounts();
    if (existingAccounts.length > 0) {
      msalInstance.setActiveAccount(existingAccounts[0]);
    }

    root.render(
      <StrictMode>
        <MsalProvider instance={msalInstance}>{app}</MsalProvider>
      </StrictMode>
    );
  });
}
