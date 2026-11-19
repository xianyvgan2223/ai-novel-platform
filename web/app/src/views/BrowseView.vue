<script setup lang="ts">
/**
 * BrowseView.vue —— 移动端数据浏览
 *
 * 交互：先在顶部选择要显示的内容（表），选中后记录在当前页下方展开；
 * 也可以点「常用内容」快速切换。旧的 /browse/:db/:table 深链接仍然有效。
 *
 * 列名用 dataLabels.ts 转成中文，JSON / 内部字段默认收起。
 */
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import { DocumentCopy, Plus, Refresh, Search } from '@element-plus/icons-vue';
import { api, formatTime, MODULE_LABELS } from '@/api';
import type { ColumnMeta, DatabaseMeta, DbKey, Row, TableMeta } from '@/api';
import { useServerStore } from '@/stores/server';
import { deviceEpoch } from '@/stores/device';
import PageHeader from '@/components/PageHeader.vue';
import RichText from '@/components/RichText.vue';
import { columnLabel, NOISY_COLUMNS, PINNED_TABLES, TABLE_HINTS } from '@/views/dataLabels';

const props = defineProps<{ db?: string; table?: string }>();

const store = useServerStore();
const router = useRouter();

const rows = ref<Row[]>([]);
const loading = ref(false);
const keyword = ref('');
const page = ref(1);
const pageSize = ref(50);
const total = ref(0);
/** 展开 JSON / 内部字段 */
const showAllColumns = ref(false);

const detailVisible = ref(false);
const detailRow = ref<Row | null>(null);
const detailJson = ref('');

const editVisible = ref(false);
const editMode = ref<'create' | 'edit'>('edit');
const editForm = reactive<Row>({});
const saving = ref(false);

const dbKey = computed(() => (props.db as DbKey) || 'deepseek');
const tableName = computed(() => props.table ?? '');
const meta = computed(() => (tableName.value ? store.tableMeta(dbKey.value, tableName.value) : undefined));
const columns = computed<ColumnMeta[]>(() => meta.value?.columns ?? []);
const listColumns = computed(() => columns.value);

/** 默认隐藏 JSON / 敏感 / 内部字段，列表更易读；需要时用「显示全部字段」打开 */
const visibleColumns = computed(() =>
  showAllColumns.value ? listColumns.value : listColumns.value.filter((col) => !NOISY_COLUMNS.has(col.name)),
);
const hiddenColumnCount = computed(() => listColumns.value.length - visibleColumns.value.length);

const tableStats = computed(() => {
  if (!tableName.value) return null;
  return store.stats?.databases?.[dbKey.value]?.tables?.[tableName.value] ?? null;
});

/* ── 内容选择 ── */

interface HubEntry {
  db: DatabaseMeta;
  table: TableMeta;
}

const hubDatabases = computed<DatabaseMeta[]>(() => {
  const dbs = store.catalog?.databases ?? [];
  // 未选表时兼容 /browse/deepseek 这种只看某个库的旧地址；选中表后允许跨库切换
  return !tableName.value && props.db ? dbs.filter((db) => db.key === props.db) : dbs;
});

const allHubTables = computed<HubEntry[]>(() =>
  hubDatabases.value.flatMap((db) => db.tables.map((table) => ({ db, table }))),
);

const pinnedTables = computed<HubEntry[]>(() => {
  const out: HubEntry[] = [];
  for (const item of PINNED_TABLES) {
    const db = hubDatabases.value.find((candidate) => candidate.key === item.db);
    const table = db?.tables.find((candidate) => candidate.name === item.table);
    if (db && table) out.push({ db, table });
  }
  return out;
});

const hubTotalRows = computed(() =>
  allHubTables.value.reduce((sum, { db, table }) => sum + store.rowCount(db.key, table.name), 0),
);

const selectedKey = computed(() => (tableName.value ? dbKey.value + '|' + tableName.value : ''));

function hintOf(entry: HubEntry): string {
  return TABLE_HINTS[entry.db.key + '.' + entry.table.name] ?? '';
}

function selectEntry(entry: HubEntry): void {
  void router.push(`/browse/${entry.db.key}/${entry.table.name}`);
}

function onSelect(value: string): void {
  if (!value) return;
  const [db, table] = value.split('|');
  if (db && table) void router.push(`/browse/${db}/${table}`);
}

function clearSelection(): void {
  void router.push('/browse');
}

async function refreshAll(): Promise<void> {
  await Promise.all([store.refreshCatalog(), store.refreshStats()]);
  if (tableName.value) await load();
}

/* ── 表浏览 ── */

/** 表单字段读写：动态列名不能直接 v-model，统一走这两个辅助函数 */
function setField(name: string, value: unknown) {
  editForm[name] = value;
}

function asNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function asText(value: unknown): string {
  return value === null || value === undefined ? '' : String(value);
}

/** 0/1 开关类字段：用 switch / 是·否 比数字输入框更直观 */
function isBoolColumn(col: ColumnMeta) {
  if (col.pk || col.type !== 'INTEGER') return false;
  return /^(is_|enable_|has_|web_search$|stream$|thinking$|logprobs$|history_query$|inject$|chosen$|enabled$|single_story$)/.test(
    col.name,
  );
}

function isTimeColumn(col: ColumnMeta): boolean {
  return /(created_at|updated_at|create_time|update_time|timestamp)$/.test(col.name);
}

function isJsonValue(value: unknown): boolean {
  if (typeof value !== 'string') return false;
  const text = value.trim();
  if (!text.startsWith('{') && !text.startsWith('[')) return false;
  try {
    JSON.parse(text);
    return true;
  } catch {
    return false;
  }
}

function prettyJson(value: unknown): string {
  try {
    return JSON.stringify(JSON.parse(String(value)), null, 2);
  } catch {
    return String(value);
  }
}

function cellPreview(value: unknown, col: ColumnMeta): string {
  if (value === null || value === undefined || value === '') return '—';
  if (isBoolColumn(col)) return asNumber(value) === 1 ? '是' : '否';
  if (isJsonValue(value)) return 'JSON 数据';
  if (isTimeColumn(col)) return formatTime(value);
  return String(value);
}

function detailHeading(): string {
  const row = detailRow.value;
  if (!row) return '';
  for (const key of ['title', 'event_title', 'name', 'copy_name', 'char_name', 'character_name', 'summary', 'last_message', 'content']) {
    const text = String(row[key] ?? '').trim();
    if (text) return text.length > 110 ? text.slice(0, 110) + '…' : text;
  }
  return '记录 #' + String(row.id ?? '');
}

function detailSubMeta(): string {
  const row = detailRow.value;
  if (!row) return '';
  const created = row.created_at ?? row.create_time ?? row.timestamp;
  const bits = ['ID ' + String(row.id ?? '—')];
  if (created) bits.push(formatTime(created));
  if (row.status) bits.push('状态：' + String(row.status));
  return bits.join(' · ');
}

async function load() {
  if (!meta.value) return;
  loading.value = true;
  try {
    const res = await api.listRows(dbKey.value, tableName.value, {
      page: page.value,
      pageSize: pageSize.value,
      q: keyword.value || undefined,
      orderBy: sortProp.value || undefined,
      dir: sortOrder.value === 'ascending' ? 'asc' : 'desc',
    });
    rows.value = res.data;
    total.value = res.meta.total;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

// 排序
const sortProp = ref('');
const sortOrder = ref<'ascending' | 'descending'>('descending');
function onSortChange(payload: { prop: string | null; order: string | null }) {
  sortProp.value = payload.order && payload.prop ? payload.prop : '';
  void load();
}

function search() {
  page.value = 1;
  void load();
}

async function openDetail(row: Row) {
  try {
    detailRow.value = await api.getRow(dbKey.value, tableName.value, Number(row.id));
    detailJson.value = JSON.stringify(detailRow.value, null, 2);
    detailVisible.value = true;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

function openCreate() {
  editMode.value = 'create';
  for (const key of Object.keys(editForm)) delete editForm[key];
  for (const col of columns.value) {
    if (!col.notNull || col.hasDefault || col.autoIncrement || col.pk) continue;
    editForm[col.name] = col.type === 'TEXT' ? '' : 0;
  }
  editVisible.value = true;
}

function openEdit(row: Row) {
  editMode.value = 'edit';
  for (const key of Object.keys(editForm)) delete editForm[key];
  for (const col of columns.value) {
    if (col.pk && editMode.value === 'edit') continue;
    editForm[col.name] = row[col.name] ?? (col.type === 'TEXT' ? '' : null);
  }
  editVisible.value = true;
}

async function save() {
  saving.value = true;
  try {
    if (editMode.value === 'create') {
      const result = await api.createRow(dbKey.value, tableName.value, editForm);
      ElMessage.success('已新增，主键 ' + result.pk);
    } else {
      await api.updateRow(dbKey.value, tableName.value, Number(editForm.id), editForm);
      ElMessage.success('已保存');
    }
    editVisible.value = false;
    await Promise.all([load(), store.refreshStats()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function remove(row: Row) {
  try {
    await ElMessageBox.confirm(
      '删除后服务端会记录变更日志；若配置了级联关系，子表数据也会被删除。确定继续？',
      '删除 ' + tableName.value + ' #' + row.id,
      { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  try {
    const result = await api.deleteRow(dbKey.value, tableName.value, Number(row.id));
    ElMessage.success('已删除 ' + result.count + ' 行');
    await Promise.all([load(), store.refreshStats()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function copyJson() {
  try {
    await navigator.clipboard.writeText(detailJson.value);
    ElMessage.success('已复制到剪贴板');
  } catch {
    ElMessage.warning('浏览器拒绝了剪贴板访问，请手动复制');
  }
}

watch(
  () => [props.db, props.table],
  () => {
    page.value = 1;
    keyword.value = '';
    showAllColumns.value = false;
    sortProp.value = '';
    detailVisible.value = false;
    rows.value = [];
    total.value = 0;
    if (tableName.value) void load();
  },
);

// 切换设备后同一张表的内容完全不同，回到第一页重新取
watch(deviceEpoch, () => {
  page.value = 1;
  detailVisible.value = false;
  void store.refreshStats();
  if (tableName.value) void load();
});

onMounted(async () => {
  await store.refreshCatalog();
  await store.refreshStats();
  if (tableName.value) await load();
});
</script>

<template>
  <div class="page">
    <PageHeader
      title="数据浏览"
      :desc="`先选择要显示的内容，选中后记录在下方展开。当前设备共 ${allHubTables.length} 张表、${hubTotalRows} 行数据。`"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="refreshAll">刷新</el-button>
      </template>
    </PageHeader>

    <!-- 第一步：选内容 -->
    <section class="card selector-card">
      <div class="selector-head">
        <div>
          <h3>选择要显示的内容</h3>
          <p>先选表；选中后下方直接展开记录，不需要再跳页。</p>
        </div>
        <span class="text-muted selector-count">{{ allHubTables.length }} 张表 · {{ hubTotalRows }} 行</span>
      </div>

      <div class="selector-row">
        <el-select
          :model-value="selectedKey"
          filterable
          placeholder="搜索并选择要显示的内容（如：大纲、正文、对话）"
          class="content-select"
          @change="(value) => onSelect(String(value))"
        >
          <el-option-group v-for="group in store.groupedTables" :key="group.db.key" :label="group.db.label">
            <template v-for="mod in group.modules" :key="mod.module">
              <el-option
                v-for="t in mod.tables"
                :key="group.db.key + '|' + t.name"
                :label="(MODULE_LABELS[mod.module] ?? mod.module) + ' · ' + t.label"
                :value="group.db.key + '|' + t.name"
              >
                <div class="select-option">
                  <span class="select-option-label">{{ t.label }}</span>
                  <span class="select-option-meta">
                    {{ MODULE_LABELS[mod.module] ?? mod.module }} · {{ store.rowCount(group.db.key, t.name) }} 行
                  </span>
                </div>
              </el-option>
            </template>
          </el-option-group>
        </el-select>

        <span class="text-muted selector-hint">数据来自当前设备，切换设备后会整体替换。</span>
      </div>

      <div v-if="pinnedTables.length" class="quick-row">
        <span class="quick-label">常用内容</span>
        <button
          v-for="entry in pinnedTables"
          :key="'pin-' + entry.db.key + '.' + entry.table.name"
          type="button"
          class="quick-chip"
          :class="{ on: selectedKey === entry.db.key + '|' + entry.table.name }"
          :title="hintOf(entry)"
          @click="selectEntry(entry)"
        >
          {{ entry.table.label }}
        </button>
      </div>
    </section>

    <!-- 第二步：展开内容 -->
    <div v-if="!tableName" class="card select-placeholder">
      <div class="placeholder-title">还没有选择内容</div>
      <div class="placeholder-sub">在上方选择一张表，或点一个「常用内容」，记录会在这里展开。</div>
    </div>

    <div v-else-if="!meta" class="card empty-hint">
      没有找到 {{ dbKey }}.{{ tableName }}，请在上方重新选择内容。
    </div>

    <div v-else class="card card-flush content-card">
      <div class="content-head">
        <div class="content-title">
          <div class="content-title-row">
            <h3>{{ meta.label }}</h3>
            <span class="mono content-key">{{ dbKey }}.{{ tableName }}</span>
            <el-tag size="small" type="info" effect="light">{{ MODULE_LABELS[meta.module] ?? meta.module }}</el-tag>
            <el-tag v-if="meta.singleton" size="small" type="warning" effect="light">单行配置表</el-tag>
          </div>
          <p>
            共 {{ total }} 行
            <template v-if="tableStats?.updatedAt"> · 最近更新 {{ formatTime(tableStats.updatedAt) }}</template>
          </p>
        </div>
        <div class="content-actions">
          <el-button type="primary" :icon="Plus" @click="openCreate">新增记录</el-button>
          <el-button :icon="Refresh" @click="refreshAll">刷新</el-button>
          <el-button @click="clearSelection">收起</el-button>
        </div>
      </div>

      <div class="card-head toolbar">
        <div class="toolbar-left">
          <el-checkbox v-model="showAllColumns" size="small" class="column-toggle">显示全部字段</el-checkbox>
          <span v-if="hiddenColumnCount" class="text-muted hidden-hint">
            已收起 {{ hiddenColumnCount }} 个 JSON / 内部字段
          </span>
        </div>
        <div class="toolbar-right">
          <el-input
            v-model="keyword"
            :disabled="!meta?.searchColumns.length"
            :placeholder="meta?.searchColumns.length ? '搜索 ' + meta.searchColumns.slice(0, 3).map(columnLabel).join(' / ') : '该表不支持搜索'"
            clearable
            class="table-search"
            @keyup.enter="search"
            @clear="search"
          >
            <template #prefix><el-icon><Search /></el-icon></template>
          </el-input>
        </div>
      </div>

      <el-alert
        v-if="tableName === 'user_settings'"
        type="warning"
        show-icon
        :closable="false"
        title="user_settings 保存着 DeepSeek API Key"
        description="导出时会自动清空 apiKey 与 baidu_api_key；在网页上修改这些字段会同步回手机。"
        style="margin: 14px 20px 0; width: auto"
      />

      <el-table
        v-loading="loading"
        :data="rows"
        style="cursor: pointer"
        @row-dblclick="openDetail"
        @sort-change="onSortChange"
      >
        <el-table-column prop="id" label="ID" width="120" sortable="custom" align="right">
          <template #header>
            <span class="col-head"><span>ID</span><span class="col-raw mono">id</span></span>
          </template>
          <template #default="{ row }">
            <span class="mono id-cell">{{ row.id }}</span>
          </template>
        </el-table-column>
        <el-table-column
          v-for="col in visibleColumns.filter((c) => c.name !== 'id')"
          :key="col.name"
          :prop="col.name"
          :min-width="col.type === 'TEXT' ? 240 : 140"
          sortable="custom"
          show-overflow-tooltip
        >
          <template #header>
            <span class="col-head">
              <span class="col-label">{{ columnLabel(col.name) }}</span>
              <span class="col-raw mono">{{ col.name }}</span>
            </span>
          </template>
          <template #default="{ row }">
            <span v-if="row[col.name] === null || row[col.name] === ''" class="text-muted">—</span>
            <span v-else-if="isBoolColumn(col)" class="bool-cell" :class="{ on: asNumber(row[col.name]) === 1 }">
              {{ asNumber(row[col.name]) === 1 ? '是' : '否' }}
            </span>
            <span v-else-if="isJsonValue(row[col.name])" class="json-cell">JSON 数据</span>
            <span v-else-if="isTimeColumn(col)" class="mono cell-num">{{ formatTime(row[col.name]) }}</span>
            <span v-else-if="col.type !== 'TEXT'" class="mono cell-num">{{ cellPreview(row[col.name], col) }}</span>
            <span v-else class="cell-text">{{ cellPreview(row[col.name], col) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="170" fixed="right" align="right">
          <template #default="{ row }">
            <el-button link type="primary" @click.stop="openDetail(row)">详情</el-button>
            <el-button link type="primary" @click.stop="openEdit(row)">编辑</el-button>
            <el-button link type="danger" @click.stop="remove(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>

      <div class="card-foot">
        <span class="text-muted" style="font-size: 12.5px">
          共 <b class="tnum">{{ total }}</b> 行 · 双击任意行查看完整内容
        </span>
        <el-pagination
          v-model:current-page="page"
          v-model:page-size="pageSize"
          :total="total"
          :page-sizes="[20, 50, 100, 200]"
          layout="sizes, prev, pager, next, jumper"
          background
          @current-change="load"
          @size-change="search"
        />
      </div>
    </div>

    <!-- 详情抽屉 -->
    <el-drawer
      v-model="detailVisible"
      :title="(meta ? meta.label : tableName) + ' #' + (detailRow?.id ?? '')"
      size="660px"
    >
      <template v-if="detailRow">
        <div class="detail-top">
          <div class="detail-heading">{{ detailHeading() }}</div>
          <div class="detail-meta">{{ detailSubMeta() }}</div>
        </div>
        <el-descriptions :column="1" size="default" border class="detail-fields">
          <el-descriptions-item v-for="col in columns" :key="col.name">
            <template #label>
              <div class="dd-label">
                <span>{{ columnLabel(col.name) }}</span>
                <span class="mono dd-raw">{{ col.name }}</span>
              </div>
            </template>
            <div class="dd-label-row">
              <span class="mono dd-type">{{ col.type }}</span>
              <el-tag v-if="col.ref" size="small" type="info" effect="plain">外键 → {{ col.ref }}</el-tag>
            </div>
            <span v-if="detailRow[col.name] === null || detailRow[col.name] === ''" class="text-muted">—</span>
            <span v-else-if="isBoolColumn(col)" class="bool-cell" :class="{ on: asNumber(detailRow[col.name]) === 1 }">
              {{ asNumber(detailRow[col.name]) === 1 ? '是' : '否' }}
            </span>
            <pre v-else-if="isJsonValue(detailRow[col.name])" class="dd-json">{{ prettyJson(detailRow[col.name]) }}</pre>
            <span v-else-if="isTimeColumn(col)" class="dd-value">{{ formatTime(detailRow[col.name]) }}</span>
            <div v-else-if="col.type === 'TEXT' && String(detailRow[col.name] ?? '').length > 60" class="dd-long">
              <RichText :text="String(detailRow[col.name] ?? '')" />
            </div>
            <span v-else class="dd-value">{{ detailRow[col.name] }}</span>
          </el-descriptions-item>
        </el-descriptions>
      </template>
      <template #footer>
        <el-button :icon="DocumentCopy" @click="copyJson">复制 JSON</el-button>
        <el-button type="primary" @click="detailVisible = false">关闭</el-button>
      </template>
    </el-drawer>

    <!-- 编辑 / 新增 -->
    <el-dialog
      v-model="editVisible"
      :title="editMode === 'create' ? '新增记录 · ' + (meta?.label ?? tableName) : '编辑记录 #' + editForm.id"
      width="780px"
      top="6vh"
    >
      <el-form label-width="170px" label-position="right" class="edit-form">
        <el-form-item v-for="col in columns" :key="col.name">
          <template #label>
            <div class="edit-label">
              <span>{{ columnLabel(col.name) }}</span>
              <span class="mono edit-raw">{{ col.name }}</span>
            </div>
          </template>
          <el-switch
            v-if="isBoolColumn(col)"
            :model-value="asNumber(editForm[col.name]) === 1"
            @update:model-value="(v: unknown) => setField(col.name, v ? 1 : 0)"
          />
          <el-input-number
            v-else-if="col.type === 'INTEGER' || col.type === 'REAL'"
            :model-value="asNumber(editForm[col.name])"
            :disabled="col.pk"
            :precision="col.type === 'REAL' ? 2 : 0"
            :step="col.type === 'REAL' ? 0.1 : 1"
            :controls-position="'right'"
            style="width: 240px"
            @update:model-value="(v: unknown) => setField(col.name, v)"
          />
          <el-input
            v-else
            :model-value="asText(editForm[col.name])"
            :disabled="col.pk"
            :type="col.type === 'TEXT' && asText(editForm[col.name]).length > 60 ? 'textarea' : 'text'"
            :rows="6"
            @update:model-value="(v: unknown) => setField(col.name, v)"
          />
          <span v-if="col.pk" class="field-hint">主键，不可修改</span>
          <span v-else-if="col.ref" class="field-hint">外键 → {{ col.ref }}</span>
          <span v-else-if="!col.notNull" class="field-hint">可空</span>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="editVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
/* ── 选内容 ── */
.selector-card {
  padding: 18px 20px;
  margin-bottom: 16px;
}

.selector-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 12px;
}

.selector-head h3 {
  margin: 0;
  font-size: 14px;
  font-weight: 600;
  color: var(--ink-1);
}

.selector-head p {
  margin: 5px 0 0;
  font-size: 11.5px;
  line-height: 1.6;
  color: var(--ink-3);
}

.selector-count { font-size: 11px; flex: 0 0 auto; }

.selector-row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}

.content-select { width: 440px; max-width: 100%; }
.selector-hint { font-size: 11px; }

.select-option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 18px;
}

.select-option-label { font-size: 12.5px; color: var(--ink-1); }
.select-option-meta { font-size: 10px; color: var(--ink-4); }

.quick-row {
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
  margin-top: 12px;
  padding-top: 11px;
  border-top: 1px solid var(--line);
}

.quick-label { font-size: 11px; color: var(--ink-3); }

.quick-chip {
  padding: 3px 9px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--bg-card);
  color: var(--ink-2);
  font-size: 11px;
  cursor: pointer;
}

.quick-chip:hover { border-color: var(--line-strong); background: var(--bg-soft); }

.quick-chip.on {
  border-color: var(--ink-3);
  background: var(--brand-soft);
  color: var(--ink-1);
  font-weight: 600;
}

/* ── 未选择 ── */
.select-placeholder {
  padding: 46px 20px;
  text-align: center;
}

.placeholder-title { font-size: 14px; font-weight: 600; color: var(--ink-1); }
.placeholder-sub { margin-top: 7px; font-size: 12px; line-height: 1.7; color: var(--ink-3); }

/* ── 展开内容 ── */
.content-card { margin-bottom: 16px; }

.content-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  padding: 15px 20px;
  border-bottom: 1px solid var(--line);
  flex-wrap: wrap;
}

.content-title { min-width: 0; }

.content-title-row {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.content-title-row h3 {
  margin: 0;
  font-size: 16px;
  font-weight: 600;
  color: var(--ink-1);
}

.content-key { color: var(--ink-4); font-size: 10.5px; }

.content-title p {
  margin: 6px 0 0;
  font-size: 11.5px;
  color: var(--ink-3);
}

.content-actions { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }

/* ── 表工具栏 ── */
.toolbar { align-items: center; flex-wrap: wrap; }
.toolbar-left { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-width: 0; }
.toolbar-right { display: flex; align-items: center; gap: 10px; }
.table-search { width: 300px; }
.column-toggle { margin-left: 2px; }
.hidden-hint { font-size: 11px; }

.col-head { display: flex; flex-direction: column; gap: 1px; line-height: 1.3; }
.col-label { color: var(--ink-1); font-weight: 600; }
.col-raw { color: var(--ink-4); font-size: 9.5px; font-weight: 400; text-transform: none; }

.id-cell { color: var(--ink-3); font-size: 12px; white-space: nowrap; }
.cell-num { color: var(--ink-2); font-size: 12.5px; }
.cell-text { color: var(--ink-2); }

.bool-cell {
  display: inline-block;
  padding: 0 6px;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: var(--bg-soft);
  color: var(--ink-4);
  font-size: 10.5px;
  line-height: 1.7;
}

.bool-cell.on {
  border-color: transparent;
  background: var(--ok-soft);
  color: var(--ok);
}

.json-cell {
  display: inline-block;
  padding: 0 6px;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 10.5px;
}

/* ── 详情 ── */
.detail-top {
  margin-bottom: 14px;
  padding: 12px 14px;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--bg-soft);
}

.detail-heading {
  font-family: var(--font-serif);
  font-size: 16px;
  font-weight: 600;
  line-height: 1.5;
  color: var(--ink-1);
  word-break: break-word;
}

.detail-meta { margin-top: 5px; font-size: 11px; color: var(--ink-3); }
.detail-fields { margin-top: 2px; }

.dd-label { display: flex; flex-direction: column; gap: 1px; line-height: 1.4; }
.dd-raw { color: var(--ink-4); font-size: 9.5px; font-weight: 400; }
.dd-label-row { display: flex; align-items: center; gap: 8px; margin-bottom: 4px; }
.dd-type { color: var(--ink-4); font-size: 11px; }
.dd-value { color: var(--ink-1); word-break: break-all; }
.dd-long {
  white-space: pre-wrap;
  line-height: 1.75;
  max-height: 300px;
  overflow: auto;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 10px 12px;
  font-size: 13px;
  color: var(--ink-2);
}

.dd-json {
  max-height: 320px;
  overflow: auto;
  margin: 0;
  padding: 9px 11px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg-soft);
  color: var(--ink-2);
  font-size: 11.5px;
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
}

/* ── 编辑 ── */
.edit-form { max-height: 62vh; overflow: auto; padding-right: 6px; }
.edit-label { display: flex; flex-direction: column; gap: 1px; line-height: 1.35; }
.edit-raw { color: var(--ink-4); font-size: 9.5px; font-weight: 400; }
.field-hint { margin-left: 10px; font-size: 11.5px; color: var(--ink-4); }

@media (max-width: 900px) {
  .selector-head { flex-direction: column; }
  .content-select { width: 100%; }
  .content-head { flex-direction: column; }
  .content-actions { width: 100%; flex-wrap: wrap; }
  .table-search { width: 100%; }
  .toolbar, .toolbar-left, .toolbar-right { width: 100%; }
}
</style>