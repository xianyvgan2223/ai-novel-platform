<script setup lang="ts">
/**
 * SyncView.vue —— 同步与备份
 *
 * 两条路径：
 *   1. 零改造：App 导出 .db → 这里上传导入；这里导出 .db → App 导入（当前可用）
 *   2. 增量同步：设备注册 + pull/push 接口（协议已定，App 端待接入，见 docs/同步协议.md）
 */
import { computed, onMounted, ref } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { CircleCheckFilled, Download, Refresh, Upload, WarningFilled } from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type { ConflictInfo, DbKey, ImportReport } from '@/api';
import { useServerStore } from '@/stores/server';
import PageHeader from '@/components/PageHeader.vue';

const store = useServerStore();

const importing = ref(false);
const exporting = ref(false);
const report = ref<ImportReport | null>(null);
const conflicts = ref<ConflictInfo[]>([]);

const importDb = ref<DbKey>('deepseek');
const importMode = ref<'merge' | 'replace'>('merge');
const sanitizeOnExport = ref(true);

const devices = computed(() => store.overview?.devices ?? []);
const serverSeq = computed(() => store.overview?.serverSeq ?? 0);

async function refresh() {
  try {
    await Promise.all([store.refreshOverview(), loadConflicts()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function loadConflicts() {
  try {
    conflicts.value = await api.conflicts();
  } catch {
    conflicts.value = [];
  }
}

/** 上传手机导出的 .db —— 用原生 fetch 走二进制接口 */
async function onFileChange(uploadFile: { raw?: File }) {
  const file = uploadFile.raw;
  if (!file) return;

  // 覆盖模式不可撤销，上传前必须二次确认（ElMessageBox 取消时会 reject）
  if (importMode.value === 'replace') {
    try {
      await ElMessageBox.confirm(
        '「覆盖」模式会先清空服务端 ' + importDb.value + ' 库的全部数据，再用上传的文件替换，操作不可撤销。',
        '确认覆盖导入',
        { type: 'warning', confirmButtonText: '我确认覆盖', cancelButtonText: '取消' },
      );
    } catch {
      return;
    }
  }

  importing.value = true;
  try {
    report.value = await api.importDb(importDb.value, file, importMode.value, 'web-upload');
    ElMessage.success('导入完成：写入 ' + report.value.totalWritten + ' 行');
    await Promise.all([store.refreshStats(), refresh()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    importing.value = false;
  }
}

async function doExport(db: DbKey) {
  exporting.value = true;
  try {
    await api.exportDb(db, sanitizeOnExport.value);
    ElMessage.success('已开始下载，把它拷到手机后在 App 里「导入数据库」');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    exporting.value = false;
  }
}

async function prune() {
  try {
    const result = await api.prune();
    ElMessage.success('已清理 ' + result.pruned + ' 条日志（水位 ' + result.upTo + '）');
    await refresh();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function registerSelf() {
  try {
    await api.push({ deviceId: 'web-console', changes: [] });
    ElMessage.success('已把 Web 端登记为同步设备');
    await refresh();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

onMounted(refresh);
</script>
<template>
  <div class="page">
    <PageHeader
      title="同步与备份"
      desc="推荐路径：手机 App 导出数据库 → 上传到这里编辑 → 导出 .db → 手机 App 导入。增量同步接口已就绪，App 端接入后可自动双向同步。"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="refresh">刷新状态</el-button>
      </template>
    </PageHeader>

    <el-row :gutter="18" class="step-row">
      <!-- ① 导入 -->
      <el-col :xs="24" :lg="12">
        <div class="card card-flush step-card">
          <div class="card-head">
            <h3><span class="step">1</span> 导入 App 数据</h3>
            <span class="step-hint">手机 → Web</span>
          </div>
          <div class="card-body">
            <el-form label-width="96px" label-position="left">
              <el-form-item label="目标库">
                <el-radio-group v-model="importDb">
                  <el-radio-button value="deepseek">deepseek.db</el-radio-button>
                  <el-radio-button value="novel">novel.db</el-radio-button>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="导入方式">
                <el-radio-group v-model="importMode">
                  <el-radio value="merge">合并（按主键覆盖同 ID 记录）</el-radio>
                  <el-radio value="replace">覆盖（先清空服务端）</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="数据库文件">
                <el-upload :auto-upload="false" :show-file-list="false" accept=".db" :on-change="onFileChange as any">
                  <el-button type="primary" :loading="importing" :icon="Upload">选择 .db 文件并导入</el-button>
                </el-upload>
              </el-form-item>
            </el-form>
            <div class="tip">在 App 内「设置 → 导出数据库」拿到 deepseek_backup.db，再在此上传。</div>
          </div>
        </div>
      </el-col>

      <!-- ② 导出 -->
      <el-col :xs="24" :lg="12">
        <div class="card card-flush step-card">
          <div class="card-head">
            <h3><span class="step">2</span> 导出回手机</h3>
            <span class="step-hint">Web → 手机</span>
          </div>
          <div class="card-body">
            <el-form label-width="96px" label-position="left">
              <el-form-item label="敏感字段">
                <el-switch v-model="sanitizeOnExport" active-text="清空 API Key" inactive-text="保留 API Key" />
              </el-form-item>
              <el-form-item label="导出文件">
                <el-button type="primary" :loading="exporting" :icon="Download" @click="doExport('deepseek')">
                  deepseek.db
                </el-button>
                <el-button :loading="exporting" :icon="Download" @click="doExport('novel')">novel.db</el-button>
              </el-form-item>
            </el-form>
            <div class="tip">
              文件含 17 张 App 表、<span class="mono">user_version = 32</span>，不含任何同步元数据；
              在 App 内「设置 → 导入数据库」即可载入。
            </div>
          </div>
        </div>
      </el-col>
    </el-row>

    <!-- 导入结果 -->
    <div v-if="report" class="card card-flush report">
      <div class="card-head">
        <h3 class="row-gap"><el-icon class="ok-icon"><CircleCheckFilled /></el-icon> 导入完成</h3>
        <span class="mono text-muted">来源版本 v{{ report.sourceVersion }}</span>
      </div>
      <div class="card-body">
        <div class="report-stats">
          <div class="rs"><span class="rs-label">读取行数</span><span class="rs-value tnum">{{ report.totalRows }}</span></div>
          <div class="rs"><span class="rs-label">写入行数</span><span class="rs-value tnum brand">{{ report.totalWritten }}</span></div>
          <div class="rs"><span class="rs-label">内容未变</span><span class="rs-value tnum">{{ report.totalUnchanged }}</span></div>
          <div class="rs"><span class="rs-label">文件大小</span><span class="rs-value tnum">{{ (report.uploadedBytes / 1024).toFixed(1) }} KB</span></div>
        </div>

        <div v-if="report.warnings.length" class="warn-box">
          <div v-for="(w, i) in report.warnings" :key="i" class="warn-line">
            <el-icon><WarningFilled /></el-icon><span>{{ w }}</span>
          </div>
        </div>

        <el-table :data="Object.entries(report.tables).map(([t, s]) => ({ t, ...s }))" max-height="260" style="margin-top: 14px">
          <el-table-column prop="t" label="表" min-width="180">
            <template #default="{ row }"><span class="mono" style="font-size: 12.5px">{{ row.t }}</span></template>
          </el-table-column>
          <el-table-column prop="read" label="读取" width="90" align="right" />
          <el-table-column prop="written" label="写入" width="90" align="right">
            <template #default="{ row }">
              <span :class="row.written > 0 ? 'text-strong' : 'text-muted'">{{ row.written }}</span>
            </template>
          </el-table-column>
          <el-table-column prop="unchanged" label="未变化" width="90" align="right">
            <template #default="{ row }"><span class="text-muted">{{ row.unchanged }}</span></template>
          </el-table-column>
        </el-table>
      </div>
    </div>

    <!-- ③ 设备 -->
    <div class="card card-flush">
      <div class="card-head">
        <h3><span class="step">3</span> 增量同步状态</h3>
        <div class="row-gap">
          <span class="seq-badge mono">服务端水位 seq = {{ serverSeq }}</span>
          <el-button size="small" @click="registerSelf">登记 Web 端</el-button>
          <el-button size="small" @click="prune">清理旧日志</el-button>
        </div>
      </div>
      <el-table v-if="devices.length" :data="devices">
        <el-table-column label="设备标识" min-width="180">
          <template #default="{ row }">
            <div class="dev">
              <span class="dev-dot" />
              <span class="mono">{{ row.deviceId }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="ID 段位" width="120" align="right">
          <template #default="{ row }"><span class="mono text-muted">{{ row.idBase }}</span></template>
        </el-table-column>
        <el-table-column label="拥有行数" width="110" align="right">
          <template #default="{ row }"><span class="tnum">{{ row.rowsOwned }}</span></template>
        </el-table-column>
        <el-table-column label="拉取水位" width="110" align="right">
          <template #default="{ row }"><span class="mono">{{ row.cursor }}</span></template>
        </el-table-column>
        <el-table-column label="最后推送" width="170">
          <template #default="{ row }"><span class="text-muted">{{ row.lastPushAt ? formatTime(row.lastPushAt) : '—' }}</span></template>
        </el-table-column>
        <el-table-column label="最后拉取" width="170">
          <template #default="{ row }"><span class="text-muted">{{ row.lastPullAt ? formatTime(row.lastPullAt) : '—' }}</span></template>
        </el-table-column>
      </el-table>
      <div v-else class="empty-hint">还没有设备连接过 —— 手机端调用 /api/sync/push 后即会出现在这里</div>
    </div>

    <!-- ④ 冲突 -->
    <div class="card card-flush">
      <div class="card-head">
        <h3><span class="step">4</span> 同步冲突记录</h3>
        <span v-if="conflicts.length" class="text-muted" style="font-size: 12.5px">{{ conflicts.length }} 条</span>
      </div>
      <el-table v-if="conflicts.length" :data="conflicts">
        <el-table-column prop="id" label="ID" width="80" align="right">
          <template #default="{ row }"><span class="mono text-muted">{{ row.id }}</span></template>
        </el-table-column>
        <el-table-column prop="table" label="表" min-width="170">
          <template #default="{ row }"><span class="mono" style="font-size: 12.5px">{{ row.table }}</span></template>
        </el-table-column>
        <el-table-column prop="pk" label="主键" width="100" align="right" />
        <el-table-column prop="incomingDevice" label="来源设备" width="150" />
        <el-table-column prop="incomingRev" label="来件版本" width="110" align="right" />
        <el-table-column prop="serverRev" label="服务端版本" width="120" align="right" />
        <el-table-column label="裁决" width="130">
          <template #default="{ row }">
            <el-tag size="small" type="warning" effect="light">{{ row.resolution }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="时间" width="170">
          <template #default="{ row }"><span class="text-muted">{{ formatTime(row.detectedAt) }}</span></template>
        </el-table-column>
      </el-table>
      <div v-else class="empty-hint">暂无冲突 —— 说明没有两台设备同时改动同一行</div>
    </div>
  </div>
</template>

<style scoped>
.step-row { margin-bottom: 18px; }
.step-row :deep(.el-col) { display: flex; }
.step-card { flex: 1; margin-bottom: 0; }

.step {
  display: inline-grid;
  place-items: center;
  width: 19px;
  height: 19px;
  margin-right: 8px;
  border-radius: 6px;
  background: var(--brand);
  color: #fff;
  font-size: 11.5px;
  font-weight: 700;
  vertical-align: 1px;
}

.step-hint { font-size: 12px; color: var(--ink-4); }

.tip {
  margin-top: 2px;
  padding: 10px 12px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 9px;
  font-size: 12.5px;
  line-height: 1.65;
  color: var(--ink-3);
}

.report-stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 12px;
  margin-bottom: 4px;
}

.rs {
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 12px 14px;
}

.rs-label { display: block; font-size: 12px; color: var(--ink-3); }
.rs-value { display: block; margin-top: 3px; font-size: 22px; font-weight: 660; letter-spacing: -0.5px; }
.rs-value.brand { color: var(--brand); }

.ok-icon { color: var(--ok); font-size: 16px; }

.warn-box {
  margin-top: 14px;
  background: var(--warn-soft);
  border: 1px solid #fde68a;
  border-radius: 10px;
  padding: 10px 12px;
}

.warn-line {
  display: flex;
  align-items: flex-start;
  gap: 7px;
  font-size: 12.5px;
  line-height: 1.6;
  color: #92400e;
}
.warn-line + .warn-line { margin-top: 5px; }
.warn-line .el-icon { margin-top: 3px; color: var(--warn); flex: 0 0 auto; }

.seq-badge {
  padding: 3px 9px;
  border-radius: 6px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 11.5px;
}

.dev { display: flex; align-items: center; gap: 8px; }
.dev-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--ok);
  box-shadow: 0 0 0 3px var(--ok-soft);
}
</style>
