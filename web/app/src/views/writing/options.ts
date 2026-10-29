/** 写作优化 / 章节写作共用的动作、风格与幅度选项 */
import type { WritingAction, WritingStrength, WritingStyle } from '@/api';

export const ACTION_ITEMS: { key: WritingAction; label: string; hint: string }[] = [
  { key: 'polish', label: '润色改写', hint: '更通顺、更有语感' },
  { key: 'deai', label: '去 AI 味', hint: '打散模板句' },
  { key: 'expand', label: '扩写', hint: '补细节，约 2 倍' },
  { key: 'condense', label: '精简', hint: '压到约 60%' },
  { key: 'continue', label: '续写', hint: '接着往下写' },
  { key: 'structure', label: '结构建议', hint: '只出诊断方案' },
];

export const STYLE_OPTIONS: { key: WritingStyle; label: string }[] = [
  { key: 'original', label: '保持原味' },
  { key: 'plain', label: '日常口语' },
  { key: 'literary', label: '文学' },
  { key: 'restrained', label: '冷峻克制' },
  { key: 'hot', label: '热血' },
  { key: 'suspense', label: '悬疑' },
  { key: 'ancient', label: '古风' },
];

export const STRENGTH_OPTIONS: { key: WritingStrength; label: string }[] = [
  { key: 'light', label: '轻改' },
  { key: 'medium', label: '中改' },
  { key: 'strong', label: '重写' },
];

/** 结构建议只出方案，与其它动作互斥；扩写和精简也互斥 */
export function toggleAction(current: WritingAction[], key: WritingAction): WritingAction[] {
  if (current.includes(key)) {
    return current.filter((item) => item !== key);
  }
  if (key === 'structure') {
    return ['structure'];
  }
  let next = current.filter((item) => item !== 'structure');
  if (key === 'expand') next = next.filter((item) => item !== 'condense');
  if (key === 'condense') next = next.filter((item) => item !== 'expand');
  return [...next, key];
}
