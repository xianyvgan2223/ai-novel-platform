<script setup lang="ts">
import { computed, onMounted, ref, type Component } from 'vue';
import { useRouter } from 'vue-router';
import {
  Aim, ChatDotRound, ChatLineSquare, Collection, DataLine, Document, FolderOpened,
  InfoFilled, Notebook, Refresh, User,
} from '@element-plus/icons-vue';
import { api, formatTime, MODULE_LABELS } from '@/api';
import type { RagScene, RagStatus } from '@/api';
import { useServerStore } from '@/stores/server';
import { activeDeviceId } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';
import StatCard from '@/components/StatCard.vue';

const store = useServerStore();
const router = useRouter();

const ragStatus = ref<RagStatus | null>(null);
const ragScenes = ref<RagScene[]>([]);
const ragLoading = ref(false);
const ragError = ref('');

async function loadRag() {
  ragLoading.value = true;
  try {
    const [status, page] = await Promise.all([
      api.rag.status(),
      api.rag.scenes({ page: 1, pageSize: 3 }),
    ]);
    ragStatus.value = status;
    ragScenes.value = page.data;
    ragError.value = '';
  } catch (err) {
    ragError.value = err instanceof Error ? err.message : String(err);
  } finally {
    ragLoading.value = false;
  }
}

onMounted(() => {
  void loadRag();
});

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

    <section class="card rag-entry">
      <div class="rag-entry-head">
        <div class="rag-entry-copy">
          <div class="rag-eyebrow">RAG 情节素材库</div>
          <h3>把看过的小说，变成可复用的情节</h3>
          <p>DeepSeek 按情节拆段，百炼 embedding 生成向量，Elasticsearch 语义检索；想写类似桥段时，可以检索参考并仿写。</p>
        </div>
        <div class="rag-entry-actions">
          <el-button type="primary" @click="router.push('/rag')">进入素材库</el-button>
          <el-button @click="router.push('/rag')">导入小说</el-button>
        </div>
      </div>

      <div class="rag-entry-body" v-loading="ragLoading">
        <div class="rag-entry-stats">
          <div>
            <strong>{{ ragStatus?.totalScenes ?? '—' }}</strong>
            <span>已入库情节</span>
          </div>
          <div>
            <strong>{{ ragStatus?.totalBooks ?? '—' }}</strong>
            <span>来源作品</span>
          </div>
          <div>
            <strong>{{ ragStatus?.tags?.length ?? '—' }}</strong>
            <span>情节标签</span>
          </div>
          <div class="rag-entry-conn" :class="ragStatus?.esOnline ? 'on' : 'off'">
            <span class="dot" />
            {{ ragStatus?.esOnline ? '向量库已连接' : (ragError ? '向量库未连接' : '连接中…') }}
          </div>
        </div>

        <div v-if="ragScenes.length" class="rag-entry-scenes">
          <article v-for="scene in ragScenes" :key="scene.id" class="rag-entry-scene" @click="router.push('/rag')">
            <div class="rag-entry-scene-top">
              <span>{{ scene.sceneType || '情节' }}</span>
              <span>{{ scene.book }}</span>
            </div>
            <h4>{{ scene.title }}</h4>
            <p>{{ scene.plot }}</p>
            <div class="rag-entry-tags">
              <span v-for="tag in scene.tags.slice(0, 3)" :key="tag">{{ tag }}</span>
            </div>
          </article>
        </div>
        <div v-else class="rag-entry-empty">
          <el-icon><Collection /></el-icon>
          <div>
            <strong>{{ ragError ? '暂时无法读取向量库' : '还没有情节素材' }}</strong>
            <span>{{ ragError || '导入第一部小说 txt，素材会出现在这里。' }}</span>
          </div>
        </div>
      </div>
    </section>

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
.eb-desc { margin-top: 4px; font-size: 12.5px; line-height: 1.7; color: var(--ink-2); }

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
.db-file-desc { font-size: 12.5px; color: var(--ink-3); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.db-file-right { display: flex; align-items: center; gap: 10px; }
.db-file-count { font-size: 13px; font-weight: 600; color: var(--ink-2); }

.tbl-name { display: flex; flex-direction: column; gap: 3px; }
.tbl-label { font-weight: 600; color: var(--ink-1); font-size: 13.5px; }
.tbl-tag { color: var(--ink-3); font-size: 11.5px; }
.tbl-count { font-weight: 600; color: var(--ink-1); font-size: 14px; }
/* ── RAG 情节素材库入口 ── */
.rag-entry { margin-bottom: 18px; }
.rag-entry-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 24px; }
.rag-entry-copy { min-width: 0; }
.rag-eyebrow { font-size: 10px; font-weight: 600; letter-spacing: 1.2px; color: var(--ink-3); text-transform: uppercase; }
.rag-entry-copy h3 { margin: 7px 0 6px; font-family: var(--font-serif); font-size: 21px; font-weight: 600; letter-spacing: -0.2px; color: var(--ink-1); }
.rag-entry-copy p { margin: 0; max-width: 720px; font-size: 12.5px; line-height: 1.75; color: var(--ink-2); }
.rag-entry-actions { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }

.rag-entry-body { margin-top: 18px; padding-top: 16px; border-top: 1px solid var(--line); }
.rag-entry-stats { display: flex; align-items: center; gap: 28px; flex-wrap: wrap; }
.rag-entry-stats > div:not(.rag-entry-conn) { display: flex; align-items: baseline; gap: 8px; }
.rag-entry-stats strong { font-size: 20px; font-weight: 560; letter-spacing: -0.5px; color: var(--ink-1); }
.rag-entry-stats span { font-size: 11.5px; color: var(--ink-3); }
.rag-entry-conn { margin-left: auto; display: inline-flex; align-items: center; gap: 7px; font-size: 11.5px; color: var(--ink-2); }
.rag-entry-conn .dot { width: 5px; height: 5px; border-radius: 50%; background: var(--ink-4); }
.rag-entry-conn.on .dot { background: var(--ok); }
.rag-entry-conn.off .dot { background: var(--danger); }

.rag-entry-scenes { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin-top: 16px; }
.rag-entry-scene { padding: 14px; border: 1px solid var(--line); border-radius: var(--r-md); background: var(--bg-card); cursor: pointer; transition: border-color 0.16s ease, background 0.16s ease; }
.rag-entry-scene:hover { border-color: var(--ink-3); background: var(--bg-soft); }
.rag-entry-scene-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 10px; color: var(--ink-3); }
.rag-entry-scene-top span:last-child { max-width: 60%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rag-entry-scene h4 { margin: 7px 0 5px; font-size: 13px; font-weight: 550; line-height: 1.5; color: var(--ink-1); }
.rag-entry-scene p { margin: 0; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; font-size: 11.5px; line-height: 1.7; color: var(--ink-2); }
.rag-entry-tags { display: flex; gap: 5px; flex-wrap: wrap; margin-top: 10px; }
.rag-entry-tags span { padding: 2px 6px; border: 1px solid var(--line-strong); border-radius: 4px; font-size: 10px; color: var(--ink-3); }

.rag-entry-empty { display: flex; align-items: center; gap: 12px; padding: 16px 0 4px; color: var(--ink-3); }
.rag-entry-empty .el-icon { font-size: 22px; color: var(--ink-4); }
.rag-entry-empty div { display: flex; flex-direction: column; gap: 3px; }
.rag-entry-empty strong { font-size: 12.5px; font-weight: 550; color: var(--ink-2); }
.rag-entry-empty span { font-size: 11.5px; line-height: 1.6; }

@media (max-width: 1000px) {
  .rag-entry-scenes { grid-template-columns: minmax(0, 1fr); }
  .rag-entry-head { flex-direction: column; gap: 14px; }
}</style>
