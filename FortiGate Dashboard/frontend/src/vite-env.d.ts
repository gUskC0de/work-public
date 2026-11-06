/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL?: string;
  readonly VITE_API_PROXY_TARGET?: string;
  readonly VITE_AZURE_AD_CLIENT_ID?: string;
  readonly VITE_AZURE_AD_TENANT_ID?: string;
  readonly VITE_API_SCOPE?: string;
  readonly VITE_DEVELOPER_MODE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
