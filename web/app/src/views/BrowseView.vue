<script setup lang="ts">
/**
 * BrowseView.vue —— 通用表浏览器
 *
 * 完全由服务端 /api/catalog 返回的列元信息驱动：
 * 以后 App 新增表或字段，只要同步更新 server/src/schema.js，
 * 这里无需改一行代码即可浏览、搜索、编辑新表。
 */
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import { DocumentCopy, Plus, Refresh, Search } from '@element-plus/icons-vue';
import { api, formatTime, MODULE_LABELS } from '@/api';
import type { ColumnMeta, DbKey, Row } from '@/api';
import { useServerStore } from '@/stores/server';
import PageHeader from '@/components/PageHeader.vue';
import RichText from '@/components/RichText.vue';

const props = withDefaults(defineProps<{ db?: string; table?: string }>(), {
  db: 'deepseek',
  table: 'chat_sessions',
});

const store = useServerStore();
const router = useRouter();

const rows = ref<Row[]>([]);
const loading = ref(false);
const keyword = ref('');
const page = ref(1);
const pageSize = ref(50);
const total = ref(0);

const detailVisible = ref(false);
const detailRow = ref<Row | null>(null);
const detailJson = ref('');

const editVisible = ref(false);
const editMode = ref<'create' | 'edit'>('edit');
const editForm = reactive<Row>({});
const saving = ref(false);

const dbKey = computed(() => props.db as DbKey);
const tableName = computed(() => props.table);
const meta = computed(() => store.tableMeta(dbKey.value, tableName.value));
const columns = computed<ColumnMeta[]>(() => meta.value?.columns ?? []);
/** 展示全部列：长文本由服务端统一截断（打开详情可取全文） */
const listColumns = computed(() => columns.value);

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

/** 0/1 开关类字段：用 switch 比数字输入框更直观 */
function isBoolColumn(col: ColumnMeta) {
  if (col.pk || col.type !== 'INTEGER') return false;
  return /^(is_|enable_|has_|web_search$|stream$|thinking$|logprobs$|history_query$)/.test(col.name);
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

function switchTable(value: string) {
  const [db, table] = value.split('|');
  void router.push('/browse/' + db + '/' + table);
  keyword.value = '';
  page.value = 1;
  sortProp.value = '';
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
  // 只预填「必填且无默认值」的列：其余列留空，由服务端套用表定义的默认值
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

/** 单元格预览：空值占位 + ISO 时间友好化（长文本服务端已截断，这里不再二次裁剪） */
function preview(value: unknown, col: ColumnMeta): string {
  if (value === null || value === undefined || value === '') return '-';
  if (col.type !== 'TEXT' && typeof value === 'string' && /\d{4}-\d{2}-\d{2}T/.test(value)) return formatTime(value);
  return String(value);
}

watch(
  () => [props.db, props.table],
  () => {
    page.value = 1;
    keyword.value = '';
    void load();
  },
);

onMounted(async () => {
  await store.refreshCatalog();
  await load();
});
</script>
<template>
  <div class="page">
    <PageHeader
      title="数据浏览"
      :desc="meta ? '当前查看 ' + meta.label + '（' + dbKey + '.' + tableName + '），双击任意行查看完整字段。' : '从右上角选择要查看的表。'"
    >
      <template #actions>
        <el-button type="primary" :icon="Plus" @click="openCreate">新增记录</el-button>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div class="card card-flush">
      <div class="card-head toolbar">
        <div class="toolbar-left">
          <el-select :model-value="dbKey + '|' + tableName" style="width: 330px" filterable @change="switchTable">
            <el-option-group v-for="group in store.groupedTables" :key="group.db.key" :label="group.db.label">
              <template v-for="mod in group.modules" :key="mod.module">
                <el-option
                  v-for="t in mod.tables"
                  :key="group.db.key + '|' + t.name"
                  :label="(MODULE_LABELS[mod.module] ?? mod.module) + ' · ' + t.label"
                  :value="group.db.key + '|' + t.name"
                />
              </template>
            </el-option-group>
          </el-select>
          <el-tag v-if="meta" size="small" type="info" effect="light">{{ MODULE_LABELS[meta.module] ?? meta.module }}</el-tag>
          <el-tag v-if="meta?.singleton" size="small" type="warning" effect="light">单行配置表</el-tag>
        </div>
        <div class="toolbar-right">
          <el-input
            v-model="keyword"
            :disabled="!meta?.searchColumns.length"
            :placeholder="meta?.searchColumns.length ? '搜索 ' + meta.searchColumns.slice(0, 3).join(' / ') : '该表不支持搜索'"
            clearable
            style="width: 300px"
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
        <el-table-column prop="id" label="ID" width="96" sortable="custom" align="right">
          <template #default="{ row }">
            <span class="mono id-cell">{{ row.id }}</span>
          </template>
        </el-table-column>
        <el-table-column
          v-for="col in listColumns.filter((c) => c.name !== 'id')"
          :key="col.name"
          :prop="col.name"
          :label="col.name"
          :min-width="col.type === 'TEXT' ? 220 : 130"
          sortable="custom"
          show-overflow-tooltip
        >
          <template #default="{ row }">
            <span v-if="row[col.name] === null || row[col.name] === ''" class="text-muted">—</span>
            <span v-else-if="col.type !== 'TEXT'" class="mono cell-num">{{ preview(row[col.name], col) }}</span>
            <span v-else class="cell-text">{{ preview(row[col.name], col) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="160" fixed="right" align="right">
          <template #default="{ row }">
            <el-button link type="primary" @click.stop="openDetail(row)">详情</el-button>
            <el-button link type="primary" @click.stop="openEdit(row)">编辑</el-button>
            <el-button link type="danger" @click.stop="remove(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>

      <div class="card-foot">
        <span class="text-muted" style="font-size: 12.5px">
          共 <b class="tnum">{{ total }}</b> 行 · 长文本默认截断，打开详情看全文
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
    <el-drawer v-model="detailVisible" :title="tableName + ' #' + (detailRow?.id ?? '')" size="640px">
      <el-descriptions v-if="detailRow" :column="1" size="default" border>
        <el-descriptions-item v-for="col in columns" :key="col.name" :label="col.name">
          <div class="dd-label-row">
            <span class="mono dd-type">{{ col.type }}</span>
            <el-tag v-if="col.ref" size="small" type="info" effect="plain">外键 → {{ col.ref }}</el-tag>
          </div>
          <div v-if="col.type === 'TEXT' && String(detailRow[col.name] ?? '').length > 60" class="dd-long">
            <RichText :text="String(detailRow[col.name] ?? '')" />
          </div>
          <span v-else-if="detailRow[col.name] === null || detailRow[col.name] === ''" class="text-muted">—</span>
          <span v-else class="dd-value">{{ detailRow[col.name] }}</span>
        </el-descriptions-item>
      </el-descriptions>
      <template #footer>
        <el-button :icon="DocumentCopy" @click="copyJson">复制 JSON</el-button>
        <el-button type="primary" @click="detailVisible = false">关闭</el-button>
      </template>
    </el-drawer>

    <!-- 编辑 / 新增 -->
    <el-dialog
      v-model="editVisible"
      :title="editMode === 'create' ? '新增记录 · ' + tableName : '编辑记录 #' + editForm.id"
      width="760px"
      top="6vh"
    >
      <el-form label-width="160px" label-position="right" class="edit-form">
        <el-form-item v-for="col in columns" :key="col.name" :label="col.name">
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
.toolbar { align-items: center; }
.toolbar-left { display: flex; align-items: center; gap: 10px; }
.toolbar-right { display: flex; align-items: center; gap: 10px; }

.id-cell { color: var(--ink-3); font-size: 12px; }
.cell-num { color: var(--ink-2); font-size: 12.5px; }
.cell-text { color: var(--ink-2); }

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

.edit-form { max-height: 62vh; overflow: auto; padding-right: 6px; }
.field-hint { margin-left: 10px; font-size: 11.5px; color: var(--ink-4); }
</style>
