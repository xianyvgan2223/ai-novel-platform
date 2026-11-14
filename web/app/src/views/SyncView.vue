<script setup lang="ts">
/**
 * SyncView.vue —— 同步与备份
 *
 * 三条路径：
 *   1. 增量同步：设备注册 + pull/push 接口。**每台设备一个独立槽位**，
 *      手机之间不会互相同步（见 docs/同步协议.md 第 2 节）
 *   2. 零改造：App 导出 .db → 这里上传导入；这里导出 .db → App 导入
 *      导入 / 导出都作用于「当前选中的设备」
 *   3. 「请求整库同步」：让某台手机把整库变化推上来，并拉回电脑上的修改（手机会弹窗确认）
 */
import { computed, onMounted, ref, watch } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { CircleCheckFilled, Delete, Download, Refresh, Upload, WarningFilled } from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type { ConflictInfo, DbKey, ImportReport } from '@/api';
import { useServerStore } from '@/stores/server';
import { activeDeviceId, deviceEpoch } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';

const store = useServerStore();

const importing = ref(false);
const exporting = ref(false);
const report = ref<ImportReport | null>(null);
const conflicts = ref<ConflictInfo[]>([]);

const importDb = ref<DbKey>('deepseek');
const importMode = ref<'merge' | 'replace'>('merge');
const sanitizeOnExport = ref(true);

const devices = computed(() => store.overview?.devices ?? store.devices);
const deviceSeq = computed(() => store.overview?.deviceSeq ?? 0);

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

/** 上传手机导出的 .db —— 用原生 fetch 走二进制接口，数据落进当前设备的槽位 */
async function onFileChange(uploadFile: { raw?: File }) {
  const file = uploadFile.raw;
  if (!file) return;

  // 覆盖模式不可撤销，上传前必须二次确认（ElMessageBox 取消时会 reject）
  if (importMode.value === 'replace') {
    try {
      await ElMessageBox.confirm(
        '「覆盖」模式会先清空服务端「' + activeDeviceId.value + '」这一台设备的 ' + importDb.value + ' 库，再用上传的文件替换，操作不可撤销。',
        '确认覆盖导入',
        { type: 'warning', confirmButtonText: '我确认覆盖', cancelButtonText: '取消' },
      );
    } catch {
      return;
    }
  }

  importing.value = true;
  try {
    report.value = await api.importDb(importDb.value, file, importMode.value);
    ElMessage.success('导入完成：写入 ' + report.value.totalWritten + ' 行到设备 ' + (report.value.targetDevice ?? activeDeviceId.value));
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
    ElMessage.success('已开始下载（设备 ' + activeDeviceId.value + ' 的数据），把它拷到手机后在 App 里「导入数据库」');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    exporting.value = false;
  }
}

async function prune() {
  try {
    const result = await api.prune();
    ElMessage.success('已清理设备 ' + result.deviceId + ' 的 ' + result.pruned + ' 条日志（水位 ' + result.upTo + '）');
    await refresh();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

/** 切换「当前设备」——所有数据都换成那台设备的 */
async function pickDevice(deviceId: string) {
  await store.switchDevice(deviceId);
  report.value = null;
  await refresh();
}

/** 删掉某台设备在服务端的数据（手机本地库不受影响） */
async function forgetDevice(deviceId: string) {
  if (deviceId === 'web-console') return;
  try {
    await ElMessageBox.confirm(
      '将删除服务端为「' + deviceId + '」保存的全部数据（独立数据库文件），手机本地数据不受影响。\n' +
        '下次手机同步会重新推一份上来。此操作不可撤销。',
      '删除该设备的数据',
      { type: 'warning', confirmButtonText: '我确认删除', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  try {
    const result = await api.removeDevice(deviceId);
    ElMessage.success('已删除 ' + result.deviceId + (result.purgedFiles ? ' 的数据目录' : ' 的记录'));
    if (activeDeviceId.value === deviceId) await store.switchDevice('web-console', { silent: true });
    await refresh();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

/** 让某台手机把本机数据推上来（不指定则任何手机都能领取） */
async function requestSync(deviceId: string) {
  try {
    const request = await api.requestPhoneSync(deviceId === 'web-console' ? '' : deviceId);
    ElMessage.success(
      '已发起整库同步请求（' + (request.targetDevice || '任意手机') + '，待办 #' + request.id + '）。' +
        '手机 App 在前台时会弹窗确认，同意后才执行。',
    );
    await refresh();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

watch(deviceEpoch, () => void refresh());
onMounted(refresh);
</script>
<template>
  <div class="page">
    <PageHeader
      title="同步与备份"
      desc="每台设备在服务端有独立数据库：手机之间不会互相同步、不会互相覆盖。下面所有操作都作用于「当前设备」。"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="refresh">刷新状态</el-button>
      </template>
    </PageHeader>

    <!-- v1 遗留共享库：升级后不再自动读取，提示可手动导入 -->
    <el-alert
      v-if="store.health?.legacyFiles?.length"
      type="warning"
      show-icon
      :closable="false"
      class="legacy-alert"
      title="检测到旧版本的共享数据库文件"
      :description="'data/ 下的 ' + store.health.legacyFiles.join('、') + ' 不再被自动读取（每台设备现在各有独立目录）。需要里面的数据：先在右上角选中目标设备，再用下面的「导入 App 数据」上传该文件。'"
    />

    <!-- 当前设备：所有导入导出的落点 -->
    <div class="card card-flush device-bar">
      <div class="card-head">
        <h3>当前设备</h3>
        <span class="text-muted" style="font-size: 12.5px">
          导入 / 导出 / 浏览 / 编辑都只影响这一台设备的数据
        </span>
      </div>
      <div class="card-body">
        <el-radio-group :model-value="activeDeviceId" @change="(v: any) => pickDevice(String(v))">
          <el-radio-button v-for="device in devices" :key="device.deviceId" :value="device.deviceId">
            {{ device.deviceId === 'web-console' ? 'Web 控制台' : (device.name || device.deviceId) }}
          </el-radio-button>
        </el-radio-group>
        <div class="tip" style="margin-top: 12px">
          当前槽位 <span class="mono">{{ activeDeviceId }}</span> ·
          拉取水位 <span class="mono">seq {{ deviceSeq }}</span> ·
          数据目录 <span class="mono">data/devices/{{ activeDeviceId }}/</span>
        </div>
      </div>
    </div>

    <el-row :gutter="18" class="step-row">
      <!-- ① 导入 -->
      <el-col :xs="24" :lg="12">
        <div class="card card-flush step-card">
          <div class="card-head">
            <h3><span class="step">1</span> 导入 App 数据</h3>
            <span class="step-hint">手机 → 设备「{{ activeDeviceId }}」</span>
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
                  <el-radio value="replace">覆盖（先清空该设备的数据）</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="数据库文件">
                <el-upload :auto-upload="false" :show-file-list="false" accept=".db" :on-change="onFileChange as any">
                  <el-button type="primary" :loading="importing" :icon="Upload">选择 .db 文件并导入</el-button>
                </el-upload>
              </el-form-item>
            </el-form>
            <div class="tip">
              在 App 内「设置 → 导出数据库」拿到 deepseek_backup.db，再在此上传。
              想把 A 手机的数据给 B 手机？先切到 B，再上传 A 导出的文件即可。
            </div>
          </div>
        </div>
      </el-col>

      <!-- ② 导出 -->
      <el-col :xs="24" :lg="12">
        <div class="card card-flush step-card">
          <div class="card-head">
            <h3><span class="step">2</span> 导出回手机</h3>
            <span class="step-hint">设备「{{ activeDeviceId }}」 → 手机</span>
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
              导出的只是当前设备这一份数据，含 17 张 App 表、<span class="mono">user_version = 32</span>，
              不含任何同步元数据；在 App 内「设置 → 导入数据库」即可载入。
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
        <h3><span class="step">3</span> 设备与数据隔离</h3>
        <div class="row-gap">
          <span class="seq-badge mono">当前设备水位 seq = {{ deviceSeq }}</span>
          <el-button size="small" @click="requestSync('web-console')">请求整库同步</el-button>
          <el-button size="small" @click="prune">清理本设备旧日志</el-button>
        </div>
      </div>
      <el-table v-if="devices.length" :data="devices">
        <el-table-column label="设备" min-width="220">
          <template #default="{ row }">
            <div class="dev">
              <span class="dev-dot" :class="{ on: row.deviceId === activeDeviceId }" />
              <div>
                <div class="text-strong">
                  {{ row.deviceId === 'web-console' ? 'Web 控制台' : (row.name || row.deviceId) }}
                  <el-tag v-if="row.deviceId === activeDeviceId" size="small" effect="light" type="primary">当前</el-tag>
                </div>
                <div class="mono text-muted" style="font-size: 11.5px">{{ row.deviceId }}</div>
              </div>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="独立数据目录" min-width="200">
          <template #default="{ row }">
            <span class="mono text-muted" style="font-size: 11.5px">data/devices/{{ row.scopeDir || row.deviceId }}/</span>
          </template>
        </el-table-column>
        <el-table-column label="行数" width="90" align="right">
          <template #default="{ row }"><span class="tnum">{{ row.rowsOwned ?? 0 }}</span></template>
        </el-table-column>
        <el-table-column label="冲突" width="80" align="right">
          <template #default="{ row }"><span class="tnum">{{ row.conflicts ?? 0 }}</span></template>
        </el-table-column>
        <el-table-column label="拉取水位" width="100" align="right">
          <template #default="{ row }"><span class="mono">{{ row.cursor }}</span></template>
        </el-table-column>
        <el-table-column label="最后推送" width="160">
          <template #default="{ row }"><span class="text-muted">{{ row.lastPushAt ? formatTime(row.lastPushAt) : '—' }}</span></template>
        </el-table-column>
        <el-table-column label="操作" width="190">
          <template #default="{ row }">
            <el-button size="small" text type="primary" @click="pickDevice(row.deviceId)">
              {{ row.deviceId === activeDeviceId ? '查看中' : '查看' }}
            </el-button>
            <el-button size="small" text @click="requestSync(row.deviceId)">请求整库同步</el-button>
            <el-popconfirm
              v-if="row.deviceId !== 'web-console'"
              title="删除服务端为这台设备保存的全部数据？手机本地不受影响。"
              confirm-button-text="删除"
              cancel-button-text="取消"
              @confirm="forgetDevice(row.deviceId)"
            >
              <template #reference>
                <el-button size="small" text type="danger" :icon="Delete">删除数据</el-button>
              </template>
            </el-popconfirm>
          </template>
        </el-table-column>
      </el-table>
      <div v-else class="empty-hint">还没有设备连接过 —— 手机端调用 /api/sync/push 后即会出现在这里</div>
      <div class="card-body" style="padding-top: 0">
        <div class="tip">
          每台设备的业务库与变更日志都放在自己的目录里，<span class="mono">change_log</span> 也是各自一份，
          所以 A 手机推上来的数据永远不会下发给 B 手机 —— 两台手机即使主键相同也不会互相覆盖。
        </div>
      </div>
    </div>

    <!-- ④ 冲突 -->
    <div class="card card-flush">
      <div class="card-head">
        <h3><span class="step">4</span> 同步冲突记录</h3>
        <span v-if="conflicts.length" class="text-muted" style="font-size: 12.5px">{{ conflicts.length }} 条（全部设备）</span>
      </div>
      <el-table v-if="conflicts.length" :data="conflicts">
        <el-table-column prop="id" label="ID" width="70" align="right">
          <template #default="{ row }"><span class="mono text-muted">{{ row.id }}</span></template>
        </el-table-column>
        <el-table-column label="设备" min-width="130">
          <template #default="{ row }"><span class="mono" style="font-size: 11.5px">{{ row.deviceId }}</span></template>
        </el-table-column>
        <el-table-column prop="table" label="表" min-width="160">
          <template #default="{ row }"><span class="mono" style="font-size: 12.5px">{{ row.table }}</span></template>
        </el-table-column>
        <el-table-column prop="pk" label="主键" width="90" align="right" />
        <el-table-column prop="incomingDevice" label="来源" width="130" />
        <el-table-column prop="incomingRev" label="来件版本" width="100" align="right" />
        <el-table-column prop="serverRev" label="服务端版本" width="110" align="right" />
        <el-table-column label="裁决" width="120">
          <template #default="{ row }">
            <el-tag size="small" type="warning" effect="light">{{ row.resolution }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="时间" width="160">
          <template #default="{ row }"><span class="text-muted">{{ formatTime(row.detectedAt) }}</span></template>
        </el-table-column>
      </el-table>
      <div v-else class="empty-hint">暂无冲突 —— 各设备的数据互相独立，同一行不会被两台设备同时改动</div>
    </div>
  </div>
</template>

<style scoped>
.step-row { margin-bottom: 18px; }
.step-row :deep(.el-col) { display: flex; }
.step-card { flex: 1; margin-bottom: 0; }

.device-bar { margin-bottom: 18px; }
.legacy-alert { margin-bottom: 18px; align-items: flex-start; }
.legacy-alert :deep(.el-alert__description) { line-height: 1.7; }

.step {
  display: inline-grid;
  place-items: center;
  width: 19px;
  height: 19px;
  margin-right: 8px;
  border-radius: 6px;
  background: var(--brand);
  color: var(--bg-page);
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
  border: 1px solid var(--line-strong);
  border-radius: 10px;
  padding: 10px 12px;
}

.warn-line {
  display: flex;
  align-items: flex-start;
  gap: 7px;
  font-size: 12.5px;
  line-height: 1.6;
  color: var(--warn);
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

.dev { display: flex; align-items: center; gap: 9px; }
.dev-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--ink-4);
  flex: 0 0 7px;
}
.dev-dot.on {
  background: var(--ok);
  box-shadow: 0 0 0 3px var(--ok-soft);
}
</style>
