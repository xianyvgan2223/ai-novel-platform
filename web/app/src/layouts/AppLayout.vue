<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { ElMessage } from 'element-plus';
import { ChatDotRound, DataLine, Grid, Iphone, Refresh, RefreshRight } from '@element-plus/icons-vue';
import { api } from '@/api';
import { useServerStore } from '@/stores/server';

const store = useServerStore();
const route = useRoute();

/**
 * 「同步手机」：网页这边读的永远是服务端实时数据，不需要同步；
 * 需要同步的是手机 —— 但手机上的数据只有手机 App 自己能读写，
 * 所以这里是「请求」：记一条待办，手机 App 在前台时轮询领取并执行。
 */
const phoneSyncBusy = ref(false);
const phoneSyncHint = ref('');
const phoneSyncPercent = ref<number | null>(null);

async function syncPhone() {
  if (phoneSyncBusy.value) return;
  phoneSyncBusy.value = true;
  phoneSyncHint.value = '已请求，等待手机响应…';
  phoneSyncPercent.value = null;
  try {
    const request = await api.requestPhoneSync();
    const deadline = Date.now() + 60000;

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
        if (!progress) phoneSyncHint.value = '手机已接收，正在同步…';
      } else if (status.status === 'done') {
        phoneSyncHint.value = '';
        phoneSyncPercent.value = null;
        ElMessage.success('手机同步完成' + (status.result ? '：' + status.result : ''));
        await store.refreshStats();
        return;
      } else if (status.status === 'failed') {
        phoneSyncHint.value = '';
        phoneSyncPercent.value = null;
        ElMessage.error('手机同步失败' + (status.result ? '：' + status.result : ''));
        return;
      }
    }

    phoneSyncHint.value = '';
    phoneSyncPercent.value = null;
    ElMessage.warning('手机没有响应（60 秒）。请确认手机 App 正在运行、且已配置过同步地址。');
  } catch (err) {
    phoneSyncHint.value = '';
    phoneSyncPercent.value = null;
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    phoneSyncBusy.value = false;
  }
}

const navItems = [
  { path: '/', label: '总览', icon: DataLine, match: (p: string) => p === '/' },
  { path: '/sessions', label: '对话会话', icon: ChatDotRound, match: (p: string) => p.startsWith('/sessions') },
  { path: '/browse/deepseek/chat_sessions', label: '数据浏览', icon: Grid, match: (p: string) => p.startsWith('/browse') },
  { path: '/sync', label: '同步与备份', icon: RefreshRight, match: (p: string) => p.startsWith('/sync') },
];

const activeMenu = computed(() => navItems.find((item) => item.match(route.path))?.path ?? '/');
const pageTitle = computed(() => (route.meta.title as string | undefined) ?? '总览');

onMounted(() => {
  void store.bootstrap();
});
</script>

<template>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-logo">DS</div>
        <div class="brand-text">
          <div class="brand-name">deepseekapp</div>
          <div class="brand-sub">Web 数据台</div>
        </div>
      </div>

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
          <div class="foot-meta mono">Node {{ store.health.node }} · API v{{ store.health.apiVersion }}</div>
        </div>
        <div v-else class="foot-card">
          <div class="foot-row"><span class="foot-dot off" /><span>服务未连接</span></div>
          <div class="foot-meta">请在 web/server 执行 npm start</div>
        </div>
      </div>
    </aside>

    <div class="main">
      <header class="topbar">
        <div class="topbar-left">
          <span class="topbar-title">{{ pageTitle }}</span>
          <span v-if="store.stats" class="topbar-badge mono">seq {{ store.stats.serverSeq }}</span>
        </div>
        <div class="topbar-right">
          <span v-if="phoneSyncHint" class="sync-hint">
            {{ phoneSyncHint }}
            <span v-if="phoneSyncPercent !== null" class="sync-pct">{{ phoneSyncPercent }}%</span>
          </span>
          <div class="status-pill" :class="store.online ? 'on' : 'off'">
            <span class="dot" />
            {{ store.online ? '同步服务已连接' : '未连接同步服务' }}
          </div>
          <el-tooltip
            content="让手机 App 把数据同步过来（需要手机 App 正在运行）"
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
          :description="store.lastError + ' —— 请先启动服务端（web/server 目录执行 npm start），然后点右上角刷新。'"
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

/* ── 侧边栏 ── */
.sidebar {
  width: 236px;
  flex: 0 0 236px;
  display: flex;
  flex-direction: column;
  background: #ffffff;
  border-right: 1px solid var(--line);
}

.brand {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 22px 20px 20px;
}

.brand-logo {
  width: 34px;
  height: 34px;
  border-radius: 10px;
  display: grid;
  place-items: center;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.3px;
  color: #fff;
  background: linear-gradient(135deg, #5b78ff, #3b57e8);
  box-shadow: 0 6px 16px -6px rgba(77, 107, 254, 0.8);
}

.brand-name {
  font-size: 14.5px;
  font-weight: 640;
  color: var(--ink-1);
  letter-spacing: -0.2px;
}

.brand-sub {
  font-size: 11.5px;
  color: var(--ink-3);
  margin-top: 1px;
}

.nav-label {
  padding: 6px 22px;
  font-size: 10.5px;
  font-weight: 600;
  letter-spacing: 0.9px;
  text-transform: uppercase;
  color: var(--ink-4);
}

.nav {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 4px 12px;
  flex: 1;
}

.nav-item {
  position: relative;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 12px;
  border-radius: 9px;
  font-size: 13.5px;
  font-weight: 500;
  color: var(--ink-2);
  text-decoration: none;
  transition: background 0.15s ease, color 0.15s ease;
}

.nav-item:hover {
  background: var(--bg-soft);
  color: var(--ink-1);
}

.nav-item.active {
  color: var(--brand);
  font-weight: 600;
  background: var(--brand-soft);
}

/* 选中项左侧的强调条，贴在侧边栏最左边 */
.nav-item.active::before {
  content: '';
  position: absolute;
  left: -12px;
  top: 50%;
  transform: translateY(-50%);
  width: 3px;
  height: 18px;
  border-radius: 0 3px 3px 0;
  background: var(--brand);
}

.nav-icon { font-size: 15px; }

.sidebar-foot { padding: 14px; }

.foot-card {
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 10px 12px;
}

.foot-row {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 12px;
  color: var(--ink-2);
}

.foot-meta {
  margin-top: 5px;
  font-size: 10.5px;
  color: var(--ink-4);
  line-height: 1.5;
}

.foot-dot, .dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  flex: 0 0 7px;
}

.foot-dot.on, .status-pill.on .dot { background: #22c55e; box-shadow: 0 0 0 3px rgba(34, 197, 94, 0.18); }
.foot-dot.off, .status-pill.off .dot { background: #f43f5e; box-shadow: 0 0 0 3px rgba(244, 63, 94, 0.18); }

/* ── 主区域 ── */
.main {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.topbar {
  height: 62px;
  flex: 0 0 62px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 0 28px;
  background: rgba(255, 255, 255, 0.88);
  backdrop-filter: saturate(180%) blur(12px);
  border-bottom: 1px solid var(--line);
  position: sticky;
  top: 0;
  z-index: 10;
}

.topbar-left { display: flex; align-items: center; gap: 10px; }

.topbar-title {
  font-size: 15px;
  font-weight: 620;
  letter-spacing: -0.2px;
}

.topbar-badge {
  padding: 2px 8px;
  border-radius: 6px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  color: var(--ink-3);
  font-size: 11px;
}

.topbar-right { display: flex; align-items: center; gap: 12px; }

.status-pill {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 5px 12px 5px 10px;
  border-radius: 999px;
  font-size: 12.5px;
  font-weight: 500;
  border: 1px solid transparent;
}

.sync-hint {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  font-size: 12.5px;
  color: var(--brand);
  background: var(--brand-soft);
  padding: 4px 11px;
  border-radius: 999px;
  white-space: nowrap;
  max-width: 380px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sync-pct {
  font-weight: 650;
  font-variant-numeric: tabular-nums;
  padding-left: 7px;
  border-left: 1px solid #c9d2ff;
}

.status-pill.on { color: #047857; background: var(--ok-soft); border-color: #d1fae5; }
.status-pill.off { color: #be123c; background: var(--danger-soft); border-color: #ffe4e9; }

.content {
  flex: 1;
  overflow: auto;
  min-height: 0;
}

/* 路由切换动画 */
.fade-slide-enter-active, .fade-slide-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }
.fade-slide-enter-from { opacity: 0; transform: translateY(6px); }
.fade-slide-leave-to { opacity: 0; transform: translateY(-4px); }
</style>
