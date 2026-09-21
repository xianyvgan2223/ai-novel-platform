/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue';
  const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, unknown>;
  export default component;
}

interface ImportMetaEnv {
  /** 同步服务地址：留空表示同源（开发时走 Vite 代理） */
  readonly VITE_API_BASE?: string;
  /** 与服务端 API_TOKEN 一致；服务端未开启鉴权时留空 */
  readonly VITE_API_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
