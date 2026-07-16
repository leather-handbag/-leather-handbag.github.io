export const SCENE_VERSION = 1;
export const WORLD_SIZE = { width: 2400, height: 1120 };

const route = (nodes) => nodes.slice(0, -1).map((node, index) => [node.code, nodes[index + 1].code]);
const node = (code, x, y, landmark) => ({ code, x, y, landmark });

export const MAP_SCENES = [
  {
    code: "plains", name: "启程平原", subtitle: "基础算法的第一簇营火", climate: "grassland",
    palette: { sky: 0xb9d8bd, ground: 0x71945f, ground2: 0x9ab878, water: 0x6ba9aa, accent: 0xf4c76d, shadow: 0x31533d },
    world: { x: 250, y: 720 }, entry: { x: 170, y: 720 }, portal: { x: 1460, y: 250 },
    nodes: [
      node("plains_implementation", 360, 690, "训练村落"), node("plains_prefix", 650, 520, "前缀河渠"),
      node("plains_greedy", 930, 650, "构造风车"), node("plains_math", 1200, 430, "数学石阵"),
      node("plains_relic", 980, 250, "折半遗迹")
    ]
  },
  {
    code: "bronze", name: "青铜海湾", subtitle: "在潮汐与群岛间选择航线", climate: "coast",
    palette: { sky: 0x95c8cf, ground: 0x9b815d, ground2: 0xc9aa72, water: 0x397f91, accent: 0xe5a85e, shadow: 0x244d59 },
    world: { x: 570, y: 600 }, entry: { x: 150, y: 680 }, portal: { x: 1480, y: 300 },
    nodes: [
      node("bronze_binary", 330, 610, "二分灯塔"), node("bronze_search", 570, 380, "搜索迷宫"),
      node("bronze_structure", 800, 650, "栈队港仓"), node("bronze_dp", 1080, 500, "DP 航海盘"),
      node("bronze_math", 1320, 330, "数论星台"), node("bronze_relic", 1060, 220, "沉船遗迹")
    ]
  },
  {
    code: "silver", name: "白银山脉", subtitle: "让常用模型成为攀登装备", climate: "mountain",
    palette: { sky: 0xb8c7d5, ground: 0x7b8b91, ground2: 0xb7c2bf, water: 0x74a4b4, accent: 0xe5eef2, shadow: 0x394c5a },
    world: { x: 850, y: 440 }, entry: { x: 160, y: 720 }, portal: { x: 1430, y: 190 },
    nodes: [
      node("silver_structure", 350, 680, "并查集矿井"), node("silver_graph", 640, 490, "最短路栈道"),
      node("silver_dp", 930, 610, "背包冰窟"), node("silver_string", 1190, 390, "字符串回声洞"),
      node("silver_relic", 900, 240, "峰顶遗迹")
    ]
  },
  {
    code: "gold", name: "黄金荒漠", subtitle: "在复杂状态中寻找方向", climate: "desert",
    palette: { sky: 0xe7c985, ground: 0xb98a49, ground2: 0xd9b66c, water: 0x4c9b90, accent: 0xffdf84, shadow: 0x6d492b },
    world: { x: 1140, y: 610 }, entry: { x: 170, y: 690 }, portal: { x: 1460, y: 250 },
    nodes: [
      node("gold_structure", 330, 630, "线段树工坊"), node("gold_graph", 580, 430, "图论古城"),
      node("gold_dp", 840, 650, "DP 棋局"), node("gold_string", 1080, 470, "字符串神殿"),
      node("gold_math", 1320, 320, "组合祭坛"), node("gold_relic", 920, 250, "沙海遗迹")
    ]
  },
  {
    code: "platinum", name: "铂金天穹", subtitle: "跨越模型之间的边界", climate: "sky",
    palette: { sky: 0x8fc4c8, ground: 0x709b95, ground2: 0xb8d4ca, water: 0x72b7c3, accent: 0xe6fbf5, shadow: 0x355d66 },
    world: { x: 1450, y: 400 }, entry: { x: 180, y: 680 }, portal: { x: 1440, y: 220 },
    nodes: [
      node("platinum_structure", 340, 620, "浮空铸造厂"), node("platinum_graph", 610, 410, "网络流枢纽"),
      node("platinum_dp", 870, 620, "优化矩阵"), node("platinum_string", 1120, 420, "后缀回廊"),
      node("platinum_math", 1350, 290, "数论星盘"), node("platinum_relic", 850, 240, "浮岛遗迹")
    ]
  },
  {
    code: "master", name: "大师星域", subtitle: "在陌生问题里建立秩序", climate: "space",
    palette: { sky: 0x25254b, ground: 0x554e7e, ground2: 0x8175a0, water: 0x416ea0, accent: 0xe0c6ff, shadow: 0x17172f },
    world: { x: 1770, y: 560 }, entry: { x: 150, y: 680 }, portal: { x: 1450, y: 230 },
    nodes: [
      node("master_structure", 320, 620, "动态树船坞"), node("master_graph", 580, 420, "复杂图航道"),
      node("master_math", 860, 620, "多项式星港"), node("master_probability", 1110, 440, "概率脉冲站"),
      node("master_geometry", 1340, 280, "几何星环"), node("master_relic", 850, 230, "失落卫星")
    ]
  },
  {
    code: "legend", name: "传奇深渊", subtitle: "抵达算法版图的未知边界", climate: "abyss",
    palette: { sky: 0x211b27, ground: 0x5f3538, ground2: 0x8d4c46, water: 0x4a2635, accent: 0xff9b65, shadow: 0x160e18 },
    world: { x: 2100, y: 350 }, entry: { x: 150, y: 700 }, portal: { x: 1480, y: 190 },
    nodes: [
      node("legend_cross", 300, 650, "综合裂谷"), node("legend_proof", 520, 430, "构造王座"),
      node("legend_opt", 760, 650, "优化熔炉"), node("legend_structure", 1000, 430, "结构机械城"),
      node("legend_math", 1240, 610, "数学观测站"), node("legend_string", 1390, 320, "字符串档案库"),
      node("legend_relic", 900, 220, "边界遗迹")
    ]
  }
].map(scene => ({ ...scene, width: 1600, height: 900, routes: route(scene.nodes) }));

export const SCENE_BY_CODE = new Map(MAP_SCENES.map(scene => [scene.code, scene]));
export const ALL_REGION_CODES = MAP_SCENES.flatMap(scene => scene.nodes.map(item => item.code));

export function validateSceneManifest() {
  const unique = new Set(ALL_REGION_CODES);
  const errors = [];
  if (ALL_REGION_CODES.length !== 41) errors.push(`expected 41 regions, received ${ALL_REGION_CODES.length}`);
  if (unique.size !== ALL_REGION_CODES.length) errors.push("duplicate region code");
  for (const scene of MAP_SCENES) {
    const codes = new Set(scene.nodes.map(item => item.code));
    const visited = new Set([scene.nodes[0]?.code]);
    let changed = true;
    while (changed) {
      changed = false;
      for (const [a, b] of scene.routes) {
        if (visited.has(a) && !visited.has(b)) { visited.add(b); changed = true; }
        if (visited.has(b) && !visited.has(a)) { visited.add(a); changed = true; }
      }
    }
    if (visited.size !== codes.size) errors.push(`${scene.code} route graph is disconnected`);
  }
  return errors;
}
