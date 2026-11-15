<script setup lang="ts">
import { computed, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { MagicStick } from '@element-plus/icons-vue';
import {
  DEFAULT_BATTLE_PROMPT, DEFAULT_CHAPTER_PROMPT, DEFAULT_OUTLINE_PROMPT, MODEL_OPTIONS,
  battleSettings, chapterSettings, outlineSettings, saveBattleSettings, saveChapterSettings, saveOutlineSettings,
} from './novelSettings';

const props = defineProps<{
  modelValue: boolean;
  kind: 'outline' | 'chapter' | 'battle';
}>();

const emit = defineEmits<{ (e: 'update:modelValue', value: boolean): void }>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const saving = ref(false);

const isOutline = computed(() => props.kind === 'outline');
const isChapter = computed(() => props.kind === 'chapter');
const isBattle = computed(() => props.kind === 'battle');
const settings = computed(() => {
  if (isOutline.value) return outlineSettings;
  if (isChapter.value) return chapterSettings;
  return battleSettings;
});
const title = computed(() => {
  if (isOutline.value) return '大纲 AI 设置';
  if (isChapter.value) return '小事件 AI 设置';
  return '战斗 AI 设置';
});

async function save() {
  if (saving.value) return;
  saving.value = true;
  try {
    if (isOutline.value) {
      await saveOutlineSettings();
    } else if (isChapter.value) {
      await saveChapterSettings();
    } else {
      await saveBattleSettings();
    }
    ElMessage.success('AI 设置已保存');
    visible.value = false;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

function resetPrompt() {
  if (isOutline.value) {
    outlineSettings.systemPrompt = DEFAULT_OUTLINE_PROMPT;
  } else if (isChapter.value) {
    chapterSettings.chapterSystemPrompt = DEFAULT_CHAPTER_PROMPT;
  } else {
    battleSettings.systemPrompt = DEFAULT_BATTLE_PROMPT;
  }
}
</script>

<template>
  <el-drawer v-model="visible" :title="title" size="420px">
    <div class="settings-body">
      <el-form label-position="top">
        <el-form-item label="模型">
          <el-select v-model="settings.model" class="full">
            <el-option v-for="item in MODEL_OPTIONS" :key="item.id" :label="item.label" :value="item.id" />
          </el-select>
        </el-form-item>

        <el-form-item :label="`温度：${settings.temperature.toFixed(1)}`">
          <el-slider v-model="settings.temperature" :min="0" :max="1.5" :step="0.1" />
          <div class="field-hint">越高越有想象力，越低越稳定贴合大纲。</div>
        </el-form-item>

        <el-form-item label="最大输出 tokens">
          <el-input-number v-model="settings.maxTokens" :min="512" :max="32768" :step="512" class="full" controls-position="right" />
        </el-form-item>

        <template v-if="!isBattle">
          <el-form-item label="深度思考">
            <el-switch v-model="settings.enableThinking" />
            <span class="field-hint inline">部分模型支持，关闭后输出更直接</span>
          </el-form-item>
        </template>

        <template v-if="isOutline">
          <el-form-item label="大纲系统提示词">
            <el-input v-model="outlineSettings.systemPrompt" type="textarea" :rows="6" />
          </el-form-item>
          <el-form-item label="粗骨架检查点">
            <el-switch v-model="outlineSettings.pauseAfterSkeleton" />
            <span class="field-hint inline">三幕粗骨架生成后暂停，可编辑后再继续</span>
          </el-form-item>
          <el-form-item label="大事件检查点">
            <el-switch v-model="outlineSettings.pauseAfterEvents" />
            <span class="field-hint inline">大事件精写完成后暂停，可编辑后再继续</span>
          </el-form-item>
          <el-form-item label="小事件检查点">
            <el-switch v-model="outlineSettings.pauseAfterMinor" />
            <span class="field-hint inline">全部小事件展开后暂停，可编辑全文</span>
          </el-form-item>
        </template>

        <template v-else-if="isChapter">
          <el-form-item label="小事件系统提示词">
            <el-input v-model="chapterSettings.chapterSystemPrompt" type="textarea" :rows="6" />
          </el-form-item>
          <el-form-item label="生成时带上剧情状态">
            <el-switch v-model="chapterSettings.enableStoryState" />
          </el-form-item>
          <div class="count-row">
            <el-form-item label="默认最少字数">
              <el-input-number v-model="chapterSettings.chapterMinWords" :min="300" :max="20000" :step="500" class="full" controls-position="right" />
            </el-form-item>
            <el-form-item label="默认最多字数">
              <el-input-number v-model="chapterSettings.chapterMaxWords" :min="300" :max="30000" :step="500" class="full" controls-position="right" />
            </el-form-item>
          </div>
        </template>

        <template v-else>
          <el-form-item label="战斗系统提示词">
            <el-input v-model="battleSettings.systemPrompt" type="textarea" :rows="8" />
          </el-form-item>
        </template>
      </el-form>

      <el-button text :icon="MagicStick" class="reset" @click="resetPrompt">恢复默认提示词</el-button>
    </div>

    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="saving" @click="save">保存设置</el-button>
    </template>
  </el-drawer>
</template>

<style scoped>
.settings-body { padding-bottom: 12px; }
.full { width: 100%; }
.field-hint { margin-top: 4px; font-size: 11.5px; color: var(--ink-4); }
.field-hint.inline { margin: 0 0 0 10px; }
.count-row { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.reset { margin-top: 4px; padding-left: 0; }
</style>
