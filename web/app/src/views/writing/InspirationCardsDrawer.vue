<script setup lang="ts">
import { computed, ref } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Delete, EditPen, MagicStick, Plus } from '@element-plus/icons-vue';
import {
  aiSettings, buildCardStatusTurns, createCard, deleteCard, streamInspiration, updateCard,
} from './inspirationApi';
import type { InspirationCard, InspirationSession, InspirationSettings } from './inspirationApi';

const props = defineProps<{
  modelValue: boolean;
  session: InspirationSession | null;
  cards: InspirationCard[];
  settings: InspirationSettings;
}>();
const emit = defineEmits<{
  (event: 'update:modelValue', value: boolean): void;
  (event: 'changed'): void;
}>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const editorVisible = ref(false);
const editor = ref<InspirationCard | null>(null);
const saving = ref(false);
const statusLoadingId = ref<number | null>(null);

function emptyCard(): InspirationCard {
  const now = new Date().toISOString();
  return {
    id: 0,
    sessionId: props.session?.id ?? 0,
    name: '',
    description: '',
    personality: '',
    experiences: '',
    skills: '',
    status: '',
    inject: true,
    createdAt: now,
    updatedAt: now,
  };
}

function openNew(): void {
  if (!props.session) {
    ElMessage.warning('先新建一个灵感会话');
    return;
  }
  editor.value = emptyCard();
  editorVisible.value = true;
}

function openEdit(card: InspirationCard): void {
  editor.value = { ...card };
  editorVisible.value = true;
}

async function saveEditor(): Promise<void> {
  const card = editor.value;
  if (!card || !props.session) return;
  if (!card.name.trim()) {
    ElMessage.warning('人物卡至少要填写姓名');
    return;
  }
  saving.value = true;
  try {
    if (card.id > 0) {
      await updateCard(card);
    } else {
      await createCard({
        sessionId: props.session.id,
        name: card.name.trim(),
        description: card.description,
        personality: card.personality,
        experiences: card.experiences,
        skills: card.skills,
        status: card.status,
        inject: card.inject,
      });
    }
    emit('changed');
    editorVisible.value = false;
    ElMessage.success('人物卡已保存');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function toggleInject(card: InspirationCard): Promise<void> {
  try {
    await updateCard({ ...card, inject: !card.inject });
    emit('changed');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function remove(card: InspirationCard): Promise<void> {
  try {
    await ElMessageBox.confirm(`删除人物卡「${card.name || '未命名'}」？`, '删除人物卡', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    await deleteCard(card.id);
    emit('changed');
    ElMessage.success('已删除');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function generateStatus(card: InspirationCard): Promise<void> {
  const session = props.session;
  if (!session || statusLoadingId.value !== null) return;
  if (!card.name.trim()) {
    ElMessage.warning('先填写人物姓名');
    return;
  }
  statusLoadingId.value = card.id;
  let text = '';
  try {
    await streamInspiration(
      {
        systemPrompt: '你是小说人物设定助手，只输出人物状态正文。',
        messages: buildCardStatusTurns(card, session),
        settings: aiSettings(props.settings),
      },
      { onDelta: (delta) => { text += delta; } },
    );
    if (!text.trim()) {
      ElMessage.warning('模型没有返回状态正文，可稍后重试');
      return;
    }
    const next = { ...card, status: text.trim() };
    await updateCard(next);
    emit('changed');
    ElMessage.success('已生成当前状态并保存');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    statusLoadingId.value = null;
  }
}
</script>

<template>
  <el-drawer v-model="visible" title="人物卡" size="560px" append-to-body>
    <div class="cards-head">
      <p class="cards-desc">人物卡只在本灵感会话生效；勾选参与注入后，推演和对话都会带上。</p>
      <el-button type="primary" size="small" :icon="Plus" @click="openNew">新建人物卡</el-button>
    </div>

    <div v-if="!cards.length" class="empty-hint">还没有人物卡。可以新建，或用「AI 生成状态」补全。</div>

    <div class="card-list">
      <article v-for="card in cards" :key="card.id" class="char-card">
        <div class="char-main">
          <div class="char-head">
            <span class="char-name">{{ card.name || '未命名' }}</span>
            <el-switch
              :model-value="card.inject"
              size="small"
              inline-prompt
              active-text="注入"
              inactive-text="不注入"
              @change="() => toggleInject(card)"
            />
          </div>
          <p v-if="card.description" class="char-line">{{ card.description }}</p>
          <p v-if="card.personality" class="char-line">性格：{{ card.personality }}</p>
          <p v-if="card.status" class="char-status">状态：{{ card.status }}</p>
        </div>
        <div class="char-actions">
          <el-button
            size="small"
            text
            :icon="MagicStick"
            :loading="statusLoadingId === card.id"
            @click="generateStatus(card)"
          >
            生成状态
          </el-button>
          <el-button size="small" text :icon="EditPen" @click="openEdit(card)">编辑</el-button>
          <el-button size="small" text type="danger" :icon="Delete" @click="remove(card)">删除</el-button>
        </div>
      </article>
    </div>

    <el-dialog v-model="editorVisible" :title="editor && editor.id > 0 ? '编辑人物卡' : '新建人物卡'" width="min(560px, 94vw)" append-to-body>
      <el-form v-if="editor" label-position="top" class="card-form">
        <el-form-item label="姓名">
          <el-input v-model="editor.name" placeholder="人物姓名" />
        </el-form-item>
        <el-form-item label="描述">
          <el-input v-model="editor.description" type="textarea" :rows="2" placeholder="外貌、身份、背景" />
        </el-form-item>
        <el-form-item label="性格">
          <el-input v-model="editor.personality" type="textarea" :rows="2" placeholder="性格特点、说话方式" />
        </el-form-item>
        <el-form-item label="经历过的事件">
          <el-input v-model="editor.experiences" type="textarea" :rows="2" placeholder="已发生的关键经历" />
        </el-form-item>
        <el-form-item label="技能 / 能力">
          <el-input v-model="editor.skills" type="textarea" :rows="2" placeholder="技能、能力、底牌" />
        </el-form-item>
        <el-form-item label="当前状态">
          <el-input v-model="editor.status" type="textarea" :rows="2" placeholder="可手动填写，也可以用「生成状态」" />
        </el-form-item>
        <el-form-item label="参与注入">
          <el-switch v-model="editor.inject" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="editorVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="saveEditor">保存</el-button>
      </template>
    </el-dialog>
  </el-drawer>
</template>

<style scoped>
.cards-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.cards-desc { margin: 0; max-width: 360px; font-size: 12px; line-height: 1.7; color: var(--ink-3); }
.card-list { display: flex; flex-direction: column; gap: 8px; }
.char-card { padding: 11px 12px; border: 1px solid var(--line); border-radius: 10px; background: var(--bg-card); }
.char-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.char-name { font-size: 13.5px; font-weight: 600; color: var(--ink-1); }
.char-line { margin: 5px 0 0; font-size: 12px; line-height: 1.65; color: var(--ink-2); }
.char-status { margin: 5px 0 0; font-size: 12px; line-height: 1.65; color: var(--ink-3); }
.char-actions { display: flex; align-items: center; gap: 2px; margin-top: 7px; flex-wrap: wrap; }
.card-form :deep(.el-form-item) { margin-bottom: 12px; }
</style>