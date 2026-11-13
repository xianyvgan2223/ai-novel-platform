<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import { ChatDotRound, DataLine, Delete, Grid, Iphone, MagicStick, Monitor, Refresh, RefreshRight } from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import { useServerStore } from '@/stores/server';
import { activeDeviceId, deviceEpoch, setActiveDevice } from '@/stores/device';

const store = useServerStore();
const route = useRoute();

/**
 * 「同步手机」：网页这边读的永远是服务端实时数据，不需要同步；
 * 需要同步的是手机 —— 但手机上的数据只有手机 App 自己能读写，
 * 所以这里是「请求」：记一条待办，手机 App 在前台时轮询领取并执行。
 *
 * 指定了设备时只请求那一台：它推上来的数据只会进它自己的槽位。
 */
const phoneSyncBusy = ref(false);
const phoneSyncHint = ref('');
const phoneSyncPercent = ref<number | null>(null);
/** 只让选中的设备响应（Web 控制台自己没法响应，所以不指定） */
const syncTargetDevice = computed(() =>
  activeDeviceId.value === 'web-console' ? '' : activeDeviceId.value,
);

async function syncPhone() {
  if (phoneSyncBusy.value) return;
  phoneSyncBusy.value = true;
  phoneSyncHint.value = syncTargetDevice.value
    ? '已请求 ' + syncTargetDevice.value + '，等待手机上确认…'
    : '已请求，等待手机上确认…';
  phoneSyncPercent.value = null;
  try {
    const request = await api.requestPhoneSync(syncTargetDevice.value);
    const deadline = Date.now() + 120000;

    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const status = await api.syncRequestStatus(request.id);
      const progress = status.progress;

      // 手机把进度实时写回服务端，这里直接显示
      if (progress) {
        phoneSyncHint.value = progress.message || '正在同步…';
        phoneSyncPercent.value =
          progress.current !== null && progress.total
            ? Math.round((progress.current / progress.total) * 100)
            : null;
      }

      if (status.status === 'claimed') {
        if (!progress) phoneSyncHint.value = '手机已收到请求，等待手机上确认…';
      } else if (status.status === 'done') {
        phoneSyncHint.value = '';
        phoneSyncPercent.value = null;
        ElMessage.success('整库同步完成' + (status.result ? '：' + status.result : ''));
        await Promise.all([store.refreshStats(), store.refreshOverview().catch(() => undefined)]);
        return;
      } else if (status.status === 'rejected') {
        phoneSyncHint.value = '';
        phoneSyncPercent.value = null;
        ElMessage.warning('手机拒绝了本次同步，数据没有改动');
        return;
      } else if (status.status === 'failed') {
        phoneSyncHint.value = '';
        phoneSyncPercent.value = null;
        ElMessage.error('整库同步失败' + (status.result ? '：' + status.result : ''));
        return;
      }
    }

    phoneSyncHint.value = '';
    phoneSyncPercent.value = null;
    ElMessage.warning('手机没有响应（120 秒）。请确认手机 App 正在运行，并在手机上点「同意同步」。');
  } catch (err) {
    phoneSyncHint.value = '';
    phoneSyncPercent.value = null;
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    phoneSyncBusy.value = false;
  }
}

// ── 设备切换（数据隔离的核心入口）──

const devicePickerOpen = ref(false);

function describeDevice(deviceId: string): string {
  if (deviceId === 'web-console') return 'Web 控制台自己的槽位（上传 .db 默认落在这里）';
  return '该手机独立的数据槽位';
}

async function pickDevice(deviceId: string) {
  devicePickerOpen.value = false;
  await store.switchDevice(deviceId);
}

/** 删掉一台设备在服务端的数据；手机本地库不受影响 */
async function forgetDevice(deviceId: string) {
  if (deviceId === 'web-console') return;
  try {
    await ElMessageBox.confirm(
      '将删除服务端为「' + deviceId + '」保存的全部数据（独立数据库文件）。\n' +
        '手机本地数据不受影响，下次同步会重新推一份上来。此操作不可撤销。',
      '删除该设备的数据',
      { type: 'warning', confirmButtonText: '我确认删除', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  try {
    const result = await api.removeDevice(deviceId);
    ElMessage.success('已删除 ' + result.deviceId + (result.purgedFiles ? ' 的数据目录' : ' 的记录'));
    if (activeDeviceId.value === deviceId) setActiveDevice('web-console');
    deviceEpoch.value += 1;
    await Promise.all([store.refreshStats(), store.refreshOverview().catch(() => undefined)]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

/** 定期看一眼设备清单：新手机连上来时下拉框能自动出现 */
let deviceTimer: number | undefined;
onUnmounted(() => {
  if (deviceTimer) window.clearInterval(deviceTimer);
});

// ── 导航 ──

const navItems = [
  { path: '/', label: '总览', icon: DataLine, match: (p: string) => p === '/' },
  { path: '/sessions', label: '对话会话', icon: ChatDotRound, match: (p: string) => p.startsWith('/sessions') },
  { path: '/browse/deepseek/chat_sessions', label: '数据浏览', icon: Grid, match: (p: string) => p.startsWith('/browse') },
  { path: '/sync', label: '同步与备份', icon: RefreshRight, match: (p: string) => p.startsWith('/sync') },
];

const creativeItems = [
  { path: '/writing', label: '写作', icon: MagicStick },
];

const activeMenu = computed(() => {
  if (route.path.startsWith('/writing')) return '/writing';
  return navItems.find((item) => item.match(route.path))?.path ?? '/';
});
const pageTitle = computed(() => (route.meta.title as string | undefined) ?? '总览');

onMounted(() => {
  void store.bootstrap();
  deviceTimer = window.setInterval(() => {
    if (!store.online) return;
    void store.refreshStats().catch(() => undefined);
  }, 15000);
});
</script>

<template>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-logo">DS</div>
        <div class="brand-text">
          <div class="brand-name">deepseekapp</div>
          <div class="brand-sub">WEB CONSOLE</div>
        </div>
      </div>

      <div class="nav-label">创作</div>
      <nav class="nav nav-static">
        <router-link
          v-for="item in creativeItems"
          :key="item.path"
          :to="item.path"
          class="nav-item"
          :class="{ active: activeMenu === item.path }"
        >
          <el-icon class="nav-icon"><component :is="item.icon" /></el-icon>
          <span>{{ item.label }}</span>
        </router-link>
      </nav>

      <div class="nav-label">数据</div>
      <nav class="nav">
        <router-link
          v-for="item in navItems"
          :key="item.path"
          :to="item.path"
          class="nav-item"
          :class="{ active: activeMenu === item.path }"
        >
          <el-icon class="nav-icon"><component :is="item.icon" /></el-icon>
          <span>{{ item.label }}</span>
        </router-link>
      </nav>

      <div class="sidebar-foot">
        <div v-if="store.health" class="foot-card">
          <div class="foot-row">
            <span class="foot-dot" :class="store.online ? 'on' : 'off'" />
            <span>{{ store.online ? '服务在线' : '服务离线' }}</span>
          </div>
          <div class="foot-meta mono">JVM {{ store.health.node }} · API v{{ store.health.apiVersion }}</div>
        </div>
        <div v-else class="foot-card">
          <div class="foot-row"><span class="foot-dot off" /><span>服务未连接</span></div>
          <div class="foot-meta">请在 web/server-java 执行 mvnw spring-boot:run</div>
        </div>
      </div>
    </aside>

    <div class="main">
      <header class="topbar">
        <div class="topbar-left">
          <span class="topbar-title">{{ pageTitle }}</span>
          <span v-if="store.stats" class="topbar-badge mono">seq {{ store.stats.deviceSeq }}</span>
        </div>
        <div class="topbar-right">
          <span v-if="phoneSyncHint" class="sync-hint">
            {{ phoneSyncHint }}
            <span v-if="phoneSyncPercent !== null" class="sync-pct">{{ phoneSyncPercent }}%</span>
          </span>

          <!-- 设备切换：数据按设备隔离，这里决定「现在看谁的数据」 -->
          <el-popover v-model:visible="devicePickerOpen" placement="bottom-end" :width="360" trigger="click">
            <template #reference>
              <button class="device-picker" :class="{ busy: store.loading }" type="button">
                <el-icon class="dp-icon"><Monitor /></el-icon>
                <span class="dp-text">
                  <span class="dp-label">当前设备</span>
                  <span class="dp-name mono">{{ store.activeDeviceLabel }}</span>
                </span>
                <span class="dp-caret">▾</span>
              </button>
            </template>

            <div class="dp-panel">
              <div class="dp-panel-head">
                <div>
                  <div class="dp-panel-title">查看哪台设备的数据</div>
                  <div class="dp-panel-sub">每台设备在服务端有独立数据库，互不同步、互不覆盖</div>
                </div>
                <el-button size="small" text :icon="Refresh" @click="store.refreshStats()" />
              </div>

              <div class="dp-list">
                <button
                  v-for="device in store.devices"
                  :key="device.deviceId"
                  class="dp-item"
                  :class="{ on: device.deviceId === activeDeviceId }"
                  type="button"
                  @click="pickDevice(device.deviceId)"
                >
                  <span class="dp-item-main">
                    <span class="dp-item-name">
                      {{ device.name && device.name !== device.deviceId ? device.name : device.deviceId }}
                      <span v-if="device.deviceId === 'web-console'" class="dp-tag">Web</span>
                    </span>
                    <span class="dp-item-id mono">{{ device.deviceId }}</span>
                    <span class="dp-item-meta">
                      {{ describeDevice(device.deviceId) }}
                      · 行数 {{ device.rowsOwned ?? 0 }}
                      <template v-if="device.lastSeenAt">· 最近 {{ formatTime(device.lastSeenAt) }}</template>
                    </span>
                  </span>
                  <el-icon
                    v-if="device.deviceId !== 'web-console'"
                    class="dp-item-del"
                    title="删除该设备在服务端的数据"
                    @click.stop="forgetDevice(device.deviceId)"
                  >
                    <Delete />
                  </el-icon>
                </button>
                <div v-if="!store.devices.length" class="dp-empty">
                  还没有任何设备 —— 在手机上打开 App 同步一次即可。
                </div>
              </div>

              <div class="dp-panel-foot">
                切换后，总览 / 会话 / 数据浏览 / 导入导出都作用于该设备；手机之间不会互相同步。
              </div>
            </div>
          </el-popover>

          <div class="status-pill" :class="store.online ? 'on' : 'off'">
            <span class="dot" />
            {{ store.online ? '同步服务已连接' : '未连接同步服务' }}
          </div>
          <el-tooltip
            content="请求手机做一次整库同步：上传手机变化 + 拉回电脑上的修改（手机会弹窗确认）"
            placement="bottom-end"
          >
            <el-button :loading="phoneSyncBusy" :icon="Iphone" @click="syncPhone">同步手机</el-button>
          </el-tooltip>
          <el-tooltip content="重新拉取服务状态与表结构" placement="bottom-end">
            <el-button :loading="store.loading" :icon="Refresh" circle @click="store.bootstrap()" />
          </el-tooltip>
        </div>
      </header>

      <main class="content">
        <el-alert
          v-if="!store.online && !store.loading"
          type="error"
          show-icon
          :closable="false"
          title="无法连接同步服务"
          :description="store.lastError + ' —— 请先启动服务端（web/server-java 目录执行 mvnw spring-boot:run），然后点右上角刷新。'"
          style="margin: 18px 28px 0"
        />
        <router-view v-slot="{ Component }">
          <transition name="fade-slide" mode="out-in">
            <component :is="Component" />
          </transition>
        </router-view>
      </main>
    </div>
  </div>
</template>

<style scoped>
.shell {
  display: flex;
  height: 100%;
  background: var(--bg-page);
}

/* ── 侧边栏：深炭黑，与暖白正文形成纸张/墨色的对比 ── */
.sidebar {
  width: 232px;
  flex: 0 0 232px;
  display: flex;
  flex-direction: column;
  background: #141412;
  color: #f3efe6;
}

.brand {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 24px 20px 22px;
}

.brand-logo {
  width: 34px;
  height: 34px;
  border-radius: 9px;
  display: grid;
  place-items: center;
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.5px;
  color: #141412;
  background: #f3efe6;
}

.brand-name {
  font-size: 14px;
  font-weight: 600;
  color: #f3efe6;
  letter-spacing: 0.1px;
}

.brand-sub {
  margin-top: 2px;
  font-size: 10.5px;
  color: #7f7b72;
  letter-spacing: 0.6px;
}

.nav-label {
  padding: 8px 22px 6px;
  font-size: 9.5px;
  font-weight: 600;
  letter-spacing: 1.4px;
  text-transform: uppercase;
  color: #615e56;
}

.nav {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 2px 10px;
  flex: 1;
}

.nav-static {
  flex: 0 0 auto;
  padding-bottom: 14px;
}

.nav-item {
  position: relative;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 12px;
  border-radius: 7px;
  font-size: 12.5px;
  font-weight: 450;
  letter-spacing: 0.1px;
  color: #a7a39a;
  text-decoration: none;
  transition: background 0.16s ease, color 0.16s ease;
}

.nav-item:hover {
  background: rgba(255, 255, 255, 0.045);
  color: #f3efe6;
}

.nav-item.active {
  color: #f7f4ed;
  background: rgba(255, 255, 255, 0.075);
}

/* 选中项左侧的暖金细线，仅在深色侧栏上出现 */
.nav-item.active::before {
  content: '';
  position: absolute;
  left: -10px;
  top: 50%;
  transform: translateY(-50%);
  width: 2px;
  height: 14px;
  border-radius: 0 2px 2px 0;
  background: #c8ad82;
}

.nav-icon { font-size: 14px; opacity: 0.85; }

.sidebar-foot { padding: 14px 12px 16px; }

.foot-card {
  border: 1px solid rgba(255, 255, 255, 0.075);
  border-radius: 8px;
  padding: 11px 12px;
  background: transparent;
}

.foot-row {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 11.5px;
  color: #a7a39a;
}

.foot-meta {
  margin-top: 6px;
  font-size: 9.5px;
  color: #5f5b53;
  line-height: 1.6;
  letter-spacing: 0.2px;
}

.foot-dot, .dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  flex: 0 0 6px;
}

.foot-dot.on, .status-pill.on .dot { background: #7fa98a; }
.foot-dot.off, .status-pill.off .dot { background: #b46860; }

/* ── 主区域 ── */
.main {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.topbar {
  height: 60px;
  flex: 0 0 60px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 0 32px;
  background: rgba(245, 243, 238, 0.86);
  backdrop-filter: saturate(140%) blur(14px);
  border-bottom: 1px solid var(--line);
  position: sticky;
  top: 0;
  z-index: 10;
}

.topbar-left { display: flex; align-items: center; gap: 10px; min-width: 0; }

.topbar-title {
  font-size: 13px;
  font-weight: 550;
  letter-spacing: 0.2px;
  color: var(--ink-1);
}

.topbar-badge {
  padding: 2px 7px;
  border-radius: 4px;
  background: transparent;
  border: 1px solid var(--line-strong);
  color: var(--ink-3);
  font-size: 10px;
  letter-spacing: 0.2px;
}

.topbar-right { display: flex; align-items: center; gap: 10px; }

.status-pill {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 0;
  border: none;
  border-radius: 0;
  font-size: 11.5px;
  font-weight: 450;
  color: var(--ink-3);
  background: transparent !important;
}

.sync-hint {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 11.5px;
  color: var(--ink-2);
  background: transparent;
  padding: 0;
  border-radius: 0;
  white-space: nowrap;
  max-width: 360px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sync-pct {
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  padding-left: 6px;
  border-left: 1px solid var(--line-strong);
}

/* ── 设备切换器 ── */
.device-picker {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 6px 10px;
  border-radius: 7px;
  border: 1px solid var(--line);
  background: var(--bg-card);
  cursor: pointer;
  transition: border-color 0.15s ease;
  max-width: 300px;
}

.device-picker:hover { border-color: var(--ink-4); }
.device-picker.busy { opacity: 0.65; }
.dp-icon { color: var(--ink-3); font-size: 14px; }

.dp-text { display: flex; flex-direction: column; align-items: flex-start; min-width: 0; }
.dp-label { font-size: 9px; color: var(--ink-4); line-height: 1.25; letter-spacing: 0.3px; }

.dp-name {
  font-size: 11.5px;
  color: var(--ink-1);
  font-weight: 550;
  max-width: 230px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.dp-caret { font-size: 9px; color: var(--ink-4); }

.dp-panel-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px;
  padding-bottom: 10px;
  border-bottom: 1px solid var(--line);
}

.dp-panel-title { font-size: 12.5px; font-weight: 600; color: var(--ink-1); }
.dp-panel-sub { margin-top: 2px; font-size: 11px; color: var(--ink-3); line-height: 1.6; }

.dp-list { max-height: 320px; overflow: auto; margin: 8px 0; }

.dp-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  width: 100%;
  text-align: left;
  padding: 9px 10px;
  border-radius: 7px;
  border: 1px solid transparent;
  background: transparent;
  cursor: pointer;
  transition: background 0.15s ease;
}

.dp-item:hover { background: var(--bg-soft); }
.dp-item.on { background: var(--bg-soft); border-color: var(--line-strong); }
.dp-item-main { display: flex; flex-direction: column; gap: 2px; min-width: 0; }

.dp-item-name { font-size: 12px; font-weight: 600; color: var(--ink-1); }

.dp-tag {
  margin-left: 6px;
  padding: 1px 5px;
  border-radius: 4px;
  background: transparent;
  border: 1px solid var(--line-strong);
  color: var(--ink-3);
  font-size: 9.5px;
  font-weight: 500;
}

.dp-item-id { font-size: 10.5px; color: var(--ink-3); }
.dp-item-meta { font-size: 10px; color: var(--ink-4); line-height: 1.55; }

.dp-item-del { color: var(--ink-4); font-size: 13px; flex: 0 0 auto; }
.dp-item-del:hover { color: var(--danger); }

.dp-empty { padding: 18px 10px; font-size: 11.5px; color: var(--ink-3); text-align: center; }

.dp-panel-foot {
  padding-top: 10px;
  border-top: 1px solid var(--line);
  font-size: 10.5px;
  color: var(--ink-4);
  line-height: 1.65;
}

.content {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  min-height: 0;
}

/* 路由切换动画 */
.fade-slide-enter-active, .fade-slide-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }
.fade-slide-enter-from { opacity: 0; transform: translateY(6px); }
.fade-slide-leave-to { opacity: 0; transform: translateY(-4px); }

@media (max-width: 960px) {
  .sidebar { width: 66px; flex-basis: 66px; }
  .brand { padding: 20px 0 18px; justify-content: center; }
  .brand-text, .nav-label, .nav-item span, .sidebar-foot { display: none; }
  .nav { padding: 2px 8px; }
  .nav-static { padding-bottom: 6px; }
  .nav-item { justify-content: center; padding: 11px 0; }
  .nav-item.active::before { left: -8px; }
  .nav-icon { font-size: 16px; }
  .topbar { padding: 0 18px; gap: 10px; }
  .topbar-badge, .sync-hint { display: none; }
  .status-pill { display: none; }
  .topbar-right { gap: 7px; }
  .device-picker { max-width: 180px; padding: 5px 8px; }
  .dp-name { max-width: 110px; }
  .dp-label { display: none; }
}

@media (max-width: 700px) {
  .topbar { padding: 0 12px; gap: 6px; }
  .topbar-left { min-width: 0; flex: 1; }
  .topbar-title {
    display: block;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 12px;
  }
  .topbar-right { gap: 4px; flex: 0 0 auto; }
  .device-picker { display: flex; max-width: none; padding: 6px 8px; gap: 4px; }
  .dp-text { display: none; }
  .topbar-right :deep(.el-button span) { display: none; }
  .topbar-right :deep(.el-button) { padding: 8px; }
}
</style>