import { AppBar, Toolbar, Typography, IconButton, Box, Button, Container, Chip } from '@mui/material';
import Brightness4Icon from '@mui/icons-material/Brightness4';
import Brightness7Icon from '@mui/icons-material/Brightness7';
import { useIsAuthenticated, useMsal } from '@azure/msal-react';
import { Link as RouterLink, Outlet } from 'react-router-dom';
import { useColorMode } from '../theme/AppThemeProvider';
import { apiRequestScopes } from '../auth/authConfig';

function AuthenticationControls() {
  const { instance } = useMsal();
  const isAuthenticated = useIsAuthenticated();

  return isAuthenticated ? (
    <Button color="inherit" onClick={() => instance.logoutRedirect()}>
      Sign out
    </Button>
  ) : (
    <Button color="inherit" onClick={() => instance.loginRedirect(apiRequestScopes)}>
      Sign in
    </Button>
  );
}

export function AppLayout({ developerMode = false }: { developerMode?: boolean }) {
  const { mode, toggleColorMode } = useColorMode();

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <AppBar position="static" color="default" elevation={1}>
        <Toolbar sx={{ gap: 2 }}>
          <Typography
            variant="h6"
            component={RouterLink}
            to="/"
            sx={{ flexGrow: 1, textDecoration: 'none', color: 'inherit', fontWeight: 600 }}
          >
            FortiGate Cloud Asset Dashboard
          </Typography>
          <Button component={RouterLink} to="/" color="inherit">
            Dashboard
          </Button>
          <Button component={RouterLink} to="/devices" color="inherit">
            Devices
          </Button>
          <Button component={RouterLink} to="/psirt" color="inherit">
            PSIRT Advisories
          </Button>
          <IconButton onClick={toggleColorMode} color="inherit" aria-label="toggle dark mode">
            {mode === 'dark' ? <Brightness7Icon /> : <Brightness4Icon />}
          </IconButton>
          {developerMode ? <Chip size="small" color="warning" label="Developer mode" /> : <AuthenticationControls />}
        </Toolbar>
      </AppBar>
      <Container maxWidth={false} sx={{ py: 2, px: 3, flexGrow: 1, display: 'flex', flexDirection: 'column' }}>
        <Outlet />
      </Container>
    </Box>
  );
}
