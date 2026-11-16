import { Routes, Route } from 'react-router-dom';
import { AuthenticatedTemplate, UnauthenticatedTemplate, useMsal } from '@azure/msal-react';
import { Alert, Box, Button, Stack, Typography } from '@mui/material';
import { AppLayout } from './layout/AppLayout';
import { DashboardPage } from './pages/DashboardPage';
import { DevicesPage } from './pages/DevicesPage';
import { DeviceDetailPage } from './pages/DeviceDetailPage';
import { PsirtPage } from './pages/PsirtPage';
import { apiRequestScopes } from './auth/authConfig';
import { isDeveloperMode } from './auth/developerMode';

function SignInPrompt() {
  const { instance } = useMsal();
  return (
    <Box sx={{ display: 'flex', height: '100vh', alignItems: 'center', justifyContent: 'center' }}>
      <Stack spacing={2} alignItems="center">
        <Typography variant="h5">FortiGate Cloud Asset Dashboard</Typography>
        {apiRequestScopes.scopes.length === 0 && (
          <Alert severity="error">
            Set VITE_API_SCOPE to the exact full delegated scope from the API app registration’s Expose an API page, such as the configured Application ID URI followed by /access_as_user. A scope name alone is not valid.
          </Alert>
        )}
        <Button
          variant="contained"
          disabled={apiRequestScopes.scopes.length === 0}
          onClick={() => instance.loginRedirect(apiRequestScopes)}
        >
          Sign in with Microsoft Entra ID
        </Button>
      </Stack>
    </Box>
  );
}

export function App() {
  const routes = (
    <Routes>
      <Route element={<AppLayout developerMode={isDeveloperMode} />}>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/devices" element={<DevicesPage />} />
        <Route path="/devices/:serial" element={<DeviceDetailPage />} />
        <Route path="/psirt" element={<PsirtPage />} />
      </Route>
    </Routes>
  );

  if (isDeveloperMode) {
    return routes;
  }

  return (
    <>
      <UnauthenticatedTemplate>
        <SignInPrompt />
      </UnauthenticatedTemplate>
      <AuthenticatedTemplate>
        {routes}
      </AuthenticatedTemplate>
    </>
  );
}
