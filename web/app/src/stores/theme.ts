/**
 * 主题状态：浅色为纯白，夜间为深炭黑。
 * 首次使用跟随系统，手动切换后记在 localStorage。
 */
import { computed, ref } from 'vue';

export type ThemeMode = 'light' | 'dark';

const STORAGE_KEY = 'dsh.theme';
const media = window.matchMedia('(prefers-color-scheme: dark)');

function storedTheme(): ThemeMode | null {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value === 'light' || value === 'dark' ? value : null;
  } catch {
    return null;
  }
}

const initial = storedTheme() ?? (media.matches ? 'dark' : 'light');

export const theme = ref<ThemeMode>(initial);

function applyTheme(mode: ThemeMode) {
  const root = document.documentElement;
  root.classList.toggle('dark', mode === 'dark');
  root.dataset.theme = mode;
  root.style.colorScheme = mode;
}

applyTheme(theme.value);

export const isDark = computed(() => theme.value === 'dark');

export function setTheme(mode: ThemeMode) {
  theme.value = mode;
  applyTheme(mode);
  try {
    localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    /* 隐私模式写不进去就只在本次会话生效 */
  }
}

export function toggleTheme() {
  setTheme(theme.value === 'dark' ? 'light' : 'dark');
}

/** 没有手动选择时跟随系统切换 */
media.addEventListener('change', (event) => {
  if (storedTheme()) return;
  theme.value = event.matches ? 'dark' : 'light';
  applyTheme(theme.value);
});
