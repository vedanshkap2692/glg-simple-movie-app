/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SERVER: string;
  readonly VITE_MOCK_RESULTS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
