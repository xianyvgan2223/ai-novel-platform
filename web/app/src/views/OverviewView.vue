<script setup lang="ts">
import { computed, type Component } from 'vue';
import { useRouter } from 'vue-router';
import {
  Aim, ChatDotRound, ChatLineSquare, Collection, DataLine, Document, FolderOpened,
  InfoFilled, Notebook, Refresh, User,
} from '@element-plus/icons-vue';
import { formatTime, MODULE_LABELS } from '@/api';
import { useServerStore } from '@/stores/server';
import { activeDeviceId } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';
import StatCard from '@/components/StatCard.vue';

const store = useServerStore();
const router = useRouter();

/** 给每个统计指标配图标与配色，按 store.highlights 的 extra 匹配 */
const DECOR: Record<string, { icon: Component; tone: 'brand' | 'violet' | 'emerald' | 'amber' | 'cyan' | 'rose' }> = {
  chat_sessions: { icon: ChatDotRound, tone: 'brand' },
  chat_messages: { icon: ChatLineSquare, tone: 'cyan' },
  outline_records: { icon: Notebook, tone: 'violet' },
  outline_chapters: { icon: Document, tone: 'amber' },
  character_chat_sessions: { icon: User, tone: 'emerald' },
  world_info_entries: { icon: Collection, tone: 'cyan' },
  trpg_campaigns: { icon: Aim, tone: 'rose' },
  'novel.character_table': { icon: DataLine, tone: 'violet' },
};

const cards = computed(() =>
  store.highlights.map((item) => {
    const decor = DECOR[item.extra] ?? { icon: DataLine, tone: 'brand' as const };
    return { ...item, icon: decor.icon, tone: decor.tone, key: item.extra };
  }),
);

const totalRows = computed(() => {
  if (!store.stats?.databases) return 0;
  return Object.values(store.stats.databases).reduce((sum, db) => sum + db.total, 0);
});

const dbSummaries = computed(() => {
  if (!store.stats?.databases) return [];
  return Object.entries(store.stats.databases).map(([key, db]) => ({
    key,
    label: db.label,
    file: db.file,
    appVersion: db.appVersion,
    total: db.total,
    rows: Object.entries(db.tables)
      .map(([name, stat]) => ({
        name,
        label: store.tableMeta(key, name)?.label ?? name,
        module: MODULE_LABELS[store.tableMeta(key, name)?.module ?? ''] ?? '其他',
        count: stat.count,
        updatedAt: stat.updatedAt,
        singleton: store.tableMeta(key, name)?.singleton ?? false,
      }))
      .sort((a, b) => b.count - a.count),
  }));
});

function openTable(db: string, table: string) {
  void router.push('/browse/' + db + '/' + table);
}
</script>

<template>
  <div class="page">
    <PageHeader title="数据总览" :desc="'当前设备：' + activeDeviceId + '。每台设备在服务端有独立数据库，互不同步；可在右上角切换要查看的设备。'">
      <template #actions>
        <el-button :loading="store.loading" :icon="Refresh" @click="store.refreshStats()">重新统计</el-button>
      </template>
    </PageHeader>

    <div v-if="store.online && totalRows === 0" class="empty-banner">
      <div class="eb-icon"><el-icon><InfoFilled /></el-icon></div>
      <div class="eb-main">
        <div class="eb-title">还没有任何数据</div>
        <div class="eb-desc">
          去「同步与备份」上传手机 App 导出的 .db 文件即可开始；
          想先看看界面效果，可以把 <span class="mono">web/server/data</span> 复制一份到
          <span class="mono">data-demo2</span>，再用 <span class="mono">DATA_DIR</span> 指向它启动。
        </div>
      </div>
      <el-button type="primary" @click="router.push('/sync')">去导入数据</el-button>
    </div>

    <div class="stat-grid">
      <StatCard
        v-for="item in cards"
        :key="item.key"
        :label="item.label"
        :value="item.value"
        :hint="item.extra"
        :icon="item.icon"
        :tone="item.tone"
      />
    </div>

    <el-row :gutter="18">
      <el-col :xs="24" :lg="14">
        <div class="card card-flush" style="height: 100%">
          <div class="card-head">
            <h3>同步服务</h3>
            <span class="status-pill" :class="store.online ? 'on' : 'off'">
              <span class="dot" />{{ store.online ? '在线' : '离线' }}
            </span>
          </div>
          <div class="card-body">
            <el-descriptions v-if="store.health" :column="2" size="default" border>
              <el-descriptions-item label="JVM 版本">
                <span class="mono">{{ store.health.node }}</span>
              </el-descriptions-item>
              <el-descriptions-item label="已运行">{{ store.health.uptimeSeconds }} 秒</el-descriptions-item>
              <el-descriptions-item label="接口鉴权">
                <el-tag size="small" :type="store.health.authRequired ? 'success' : 'warning'" effect="light">
                  {{ store.health.authRequired ? '已开启' : '未开启' }}
                </el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="变更水位">
                <span class="mono">seq = {{ store.stats?.deviceSeq ?? '-' }}</span>
              </el-descriptions-item>
              <el-descriptions-item label="数据总行数">
                <span class="tnum">{{ totalRows }}</span>
              </el-descriptions-item>
              <el-descriptions-item label="服务时间">{{ formatTime(store.health.serverTime) }}</el-descriptions-item>
              <el-descriptions-item label="设备数量">
                <span class="tnum">{{ store.devices.length }}</span>
                <span class="text-muted" style="margin-left: 6px; font-size: 11.5px">各自独立数据库</span>
              </el-descriptions-item>
              <el-descriptions-item label="当前设备" :span="2">
                <span class="mono">{{ activeDeviceId }}</span>
                <span class="text-muted" style="margin-left: 6px; font-size: 11.5px">
                  （数据目录 data/devices/{{ activeDeviceId }}/）
                </span>
              </el-descriptions-item>
              <el-descriptions-item label="数据目录" :span="2">
                <span class="mono" style="word-break: break-all">{{ store.health.dataDir }}</span>
              </el-descriptions-item>
            </el-descriptions>
            <div v-else class="empty-hint">未连接到同步服务</div>
          </div>
        </div>
      </el-col>

      <el-col :xs="24" :lg="10">
        <div class="card card-flush" style="height: 100%">
          <div class="card-head">
            <h3>数据库文件</h3>
            <span class="mono text-muted" style="font-size: 11.5px">devices/{{ activeDeviceId }}/</span>
          </div>
          <div class="card-body" style="padding-bottom: 6px">
            <div v-for="db in dbSummaries" :key="db.key" class="db-file">
              <div class="db-file-icon"><FolderOpened /></div>
              <div class="db-file-main">
                <div class="db-file-name mono">{{ db.file }}</div>
                <div class="db-file-desc">{{ db.label }}</div>
              </div>
              <div class="db-file-right">
                <el-tag size="small" effect="plain" type="info">v{{ db.appVersion }}</el-tag>
                <span class="db-file-count tnum">{{ db.total }} 行</span>
              </div>
            </div>
          </div>
          <div class="card-foot" style="font-size: 12px; color: var(--ink-3)">
            这是「{{ activeDeviceId }}」这一台设备自己的文件，导出的版本号与 App 完全一致，
            App 可直接「导入数据库」；每台设备的文件互不影响。
          </div>
        </div>
      </el-col>
    </el-row>

    <div v-for="db in dbSummaries" :key="db.key" class="card card-flush">
      <div class="card-head">
        <h3>{{ db.label }}</h3>
        <span class="mono text-muted">{{ db.rows.length }} 张表 · {{ db.total }} 行</span>
      </div>
      <el-table :data="db.rows" style="cursor: pointer" @row-click="(row: any) => openTable(db.key, row.name)">
        <el-table-column label="表" min-width="240">
          <template #default="{ row }">
            <div class="tbl-name">
              <span class="tbl-label">{{ row.label }}</span>
              <span class="tbl-tag mono">{{ row.name }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column prop="module" label="所属模块" width="130" />
        <el-table-column label="行数" width="110" align="right">
          <template #default="{ row }">
            <span v-if="row.count > 0" class="tbl-count tnum">{{ row.count }}</span>
            <span v-else class="text-muted">0</span>
          </template>
        </el-table-column>
        <el-table-column label="最近变更" width="170">
          <template #default="{ row }">
            <span v-if="row.updatedAt" class="text-muted">{{ formatTime(row.updatedAt) }}</span>
            <span v-else class="text-muted">—</span>
          </template>
        </el-table-column>
        <el-table-column label="类型" width="100" align="center">
          <template #default="{ row }">
            <el-tag v-if="row.singleton" size="small" type="info" effect="light">单行配置</el-tag>
            <span v-else class="text-muted" style="font-size: 12px">普通表</span>
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>

<style scoped>
.empty-banner {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 15px 18px;
  margin-bottom: 18px;
  border-radius: var(--r-md);
  background: var(--bg-card);
  border: 1px solid var(--line);
}

.eb-icon {
  width: 28px;
  height: 28px;
  flex: 0 0 28px;
  border-radius: 50%;
  display: grid;
  place-items: center;
  background: transparent;
  border: 1px solid var(--line-strong);
  color: var(--ink-2);
  font-size: 14px;
}

.eb-main { flex: 1; }
.eb-title { font-size: 13px; font-weight: 600; color: var(--ink-1); }
.eb-desc { margin-top: 3px; font-size: 11.5px; line-height: 1.7; color: var(--ink-3); }

.status-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 3px 9px;
  border-radius: 999px;
  border: 1px solid var(--line);
  font-size: 10.5px;
  font-weight: 500;
}
.status-pill.on { color: var(--ok); background: transparent; }
.status-pill.off { color: var(--danger); background: transparent; }
.status-pill .dot { width: 5px; height: 5px; border-radius: 50%; background: currentColor; }

.db-file {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--line);
}
.db-file:last-child { border-bottom: none; }

.db-file-icon {
  width: 30px;
  height: 30px;
  flex: 0 0 30px;
  border-radius: 7px;
  display: grid;
  place-items: center;
  background: transparent;
  border: 1px solid var(--line);
  color: var(--ink-2);
  font-size: 14px;
}

.db-file-main { flex: 1; min-width: 0; }
.db-file-name { font-size: 13px; font-weight: 600; color: var(--ink-1); }
.db-file-desc { font-size: 12px; color: var(--ink-3); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.db-file-right { display: flex; align-items: center; gap: 10px; }
.db-file-count { font-size: 13px; font-weight: 600; color: var(--ink-2); }

.tbl-name { display: flex; flex-direction: column; gap: 3px; }
.tbl-label { font-weight: 600; color: var(--ink-1); font-size: 13.5px; }
.tbl-tag { color: var(--ink-4); font-size: 11px; }
.tbl-count { font-weight: 600; color: var(--ink-1); font-size: 14px; }
</style>
