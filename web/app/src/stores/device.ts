/**
 * stores/device.ts —— 「当前正在看哪台设备的数据」
 *
 * 服务端给每台设备一个独立数据槽位（见 docs/同步协议.md 第 2 节）。
 * 这个模块只做两件事：
 *   1. 记住当前选中的设备号（localStorage，刷新页面不丢）
 *   2. 让 api/client.ts 能把 x-device-id 请求头带上
 *
 * 真正的数据刷新交给 stores/server.ts 的 switchDevice()。
 */
import { ref } from 'vue';

const STORAGE_KEY = 'dsh.activeDeviceId';

/** Web 控制台自己的设备号；没有选中任何设备时用它 */
export const WEB_DEVICE_ID = 'web-console';

function readStored(): string {
  try {
    return localStorage.getItem(STORAGE_KEY) ?? '';
  } catch {
    return '';
  }
}

export const activeDeviceId = ref<string>(readStored() || WEB_DEVICE_ID);

export function setActiveDevice(deviceId: string): void {
  const next = (deviceId ?? '').trim() || WEB_DEVICE_ID;
  if (next === activeDeviceId.value) return;
  activeDeviceId.value = next;
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    /* 隐私模式下写不进去也无所谓，本次会话内仍然生效 */
  }
}

/** 设备切换时递增；页面 watch 它就能重新拉数据（比监听字符串更省心） */
export const deviceEpoch = ref(0);

export function bumpDeviceEpoch(): void {
  deviceEpoch.value += 1;
}
