import { Application, Container, Graphics, Text, TextStyle } from "pixi.js";
import { MAP_SCENES, SCENE_BY_CODE, WORLD_SIZE, validateSceneManifest } from "./training-map-scenes.js";

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const lerp = (a, b, t) => a + (b - a) * t;
const ease = t => 1 - Math.pow(1 - t, 3);
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export async function createTrainingGameMap(options) {
  const errors = validateSceneManifest();
  if (errors.length) throw new Error(`地图场景配置无效：${errors.join("；")}`);
  const game = new TrainingGameMap(options);
  await game.init();
  return game;
}

class TrainingGameMap {
  constructor({ host, labelLayer, dashboard, recommendations = [], own = true, activeMap = "plains", onMapChange, onRegionSelect, onGuardianSelect, onLockedMap, onStateChange }) {
    this.host = host;
    this.shell = host.closest(".game-map-shell");
    this.labelLayer = labelLayer;
    this.dashboard = dashboard;
    this.recommendations = recommendations;
    this.own = own;
    this.activeMap = activeMap;
    this.onMapChange = onMapChange;
    this.onRegionSelect = onRegionSelect;
    this.onGuardianSelect = onGuardianSelect;
    this.onLockedMap = onLockedMap;
    this.onStateChange = onStateChange;
    this.mode = "world";
    this.scene = null;
    this.nodeGraphics = new Map();
    this.labelButtons = [];
    this.pointerMap = new Map();
    this.drag = null;
    this.pinch = null;
    this.camera = { x: 0, y: 0, scale: 1, targetX: 0, targetY: 0, targetScale: 1 };
    this.audioEnabled = Boolean(dashboard.game_state?.audio_enabled);
    this.effectsQuality = dashboard.game_state?.effects_quality || "auto";
    this.currentRegion = dashboard.game_state?.selected_region || null;
    this.world = new Container();
    this.particles = [];
    this.animation = null;
    this.destroyed = false;
  }

  async init() {
    this.app = new Application();
    await this.app.init({ resizeTo: this.host, antialias: true, backgroundAlpha: 0, resolution: Math.min(devicePixelRatio || 1, 2), autoDensity: true, preference: "webgl" });
    this.app.canvas.className = "training-game-canvas";
    this.app.canvas.setAttribute("aria-hidden", "true");
    this.host.prepend(this.app.canvas);
    this.app.stage.addChild(this.world);
    this.bindInput();
    this.app.ticker.add(ticker => this.tick(ticker.deltaMS));
    this.showWorld(false);
    this.host.classList.add("is-ready");
    this.shell?.classList.add("is-ready");
  }

  setData(dashboard, recommendations = this.recommendations) {
    this.dashboard = dashboard;
    this.recommendations = recommendations;
    if (this.mode === "world") this.showWorld(false);
    else this.enterMap(this.activeMap, false);
  }

  get maps() { return this.dashboard.maps || []; }
  get mapData() { return this.maps.find(map => map.code === this.activeMap) || this.maps[0] || {}; }
  get nodeStateMap() { return new Map((this.dashboard.node_states || []).map(item => [item.region_code, item])); }

  clearScene() {
    this.animation = null;
    this.nodeGraphics.clear();
    this.particles.length = 0;
    this.world.removeChildren().forEach(child => child.destroy({ children: true }));
    this.labelLayer.replaceChildren();
    this.labelButtons.length = 0;
  }

  showWorld(animate = true) {
    this.clearScene();
    this.mode = "world";
    this.scene = null;
    this.drawWorldBackdrop();
    const path = new Graphics();
    for (let i = 0; i < MAP_SCENES.length - 1; i++) {
      const a = MAP_SCENES[i].world, b = MAP_SCENES[i + 1].world;
      const unlocked = Boolean(this.maps.find(item => item.code === MAP_SCENES[i + 1].code)?.unlocked);
      path.moveTo(a.x, a.y).bezierCurveTo((a.x + b.x) / 2, a.y - 120, (a.x + b.x) / 2, b.y + 120, b.x, b.y)
        .stroke({ color: unlocked ? 0xf8d88a : 0x7c796f, width: unlocked ? 9 : 5, alpha: unlocked ? .9 : .45 });
    }
    this.world.addChild(path);
    MAP_SCENES.forEach((scene, index) => this.drawWorldRealm(scene, index));
    this.drawWorldAvatar();
    this.fitScene(WORLD_SIZE.width, WORLD_SIZE.height, animate);
    this.dispatchMode();
  }

  drawWorldBackdrop() {
    const bg = new Graphics().rect(0, 0, WORLD_SIZE.width, WORLD_SIZE.height).fill(0x243c3e);
    bg.rect(0, 0, WORLD_SIZE.width, 420).fill({ color: 0x456d72, alpha: .75 });
    bg.rect(0, 420, WORLD_SIZE.width, 700).fill(0x345b55);
    this.world.addChild(bg);
    const contour = new Graphics();
    for (let i = 0; i < 24; i++) {
      const x = (i * 367) % WORLD_SIZE.width, y = 90 + (i * 173) % 900;
      contour.circle(x, y, 80 + (i % 4) * 28).stroke({ color: 0xd9d2b0, width: 2, alpha: .08 });
    }
    this.world.addChild(contour);
    this.addParticles("world", 34);
  }

  drawWorldRealm(scene, index) {
    const data = this.maps.find(map => map.code === scene.code) || {};
    const unlocked = Boolean(data.unlocked);
    const island = new Container();island.position.set(scene.world.x, scene.world.y);
    const shadow = new Graphics().ellipse(10, 25, 280, 120).fill({ color: 0x101b1c, alpha: .35 });
    const land = new Graphics().ellipse(0, 0, 265, 130).fill(unlocked ? scene.palette.ground : 0x596262).stroke({ color: unlocked ? scene.palette.accent : 0x7b8380, width: 7, alpha: .85 });
    island.addChild(shadow, land);
    this.drawMiniLandmarks(island, scene, unlocked);
    const portal = new Graphics().circle(0, -58, 28).stroke({ color: unlocked ? scene.palette.accent : 0x777d7a, width: 8, alpha: .9 });
    portal.circle(0, -58, 17).fill({ color: unlocked ? scene.palette.accent : 0x4d5553, alpha: unlocked ? .3 : .5 });island.addChild(portal);
    this.world.addChild(island);
    this.createLabel({ x: scene.world.x, y: scene.world.y + 88, title: scene.name, meta: unlocked ? `${Number(data.progress || 0)}% · ${data.mastered ? "已制霸" : "可远征"}` : "迷雾封锁", state: unlocked ? (data.mastered ? "mastered" : "available") : "locked", mapCode: scene.code, onClick: () => unlocked ? this.enterMap(scene.code, true) : this.onLockedMap?.(data) });
    if (!unlocked) {
      const fog = new Graphics();
      for (let i = 0; i < 5; i++) fog.ellipse(scene.world.x - 110 + i * 55, scene.world.y - 20 + (i % 2) * 20, 120, 60).fill({ color: 0xc9d1cc, alpha: .23 });
      this.world.addChild(fog);
    }
    const numeral = new Text({ text: String(index + 1).padStart(2, "0"), style: new TextStyle({ fill: 0xffffff, fontSize: 20, fontFamily: "monospace", fontWeight: "700" }) });
    numeral.position.set(scene.world.x - 125, scene.world.y - 78);numeral.alpha = .62;this.world.addChild(numeral);
  }

  drawMiniLandmarks(container, scene, unlocked) {
    const color = unlocked ? scene.palette.ground2 : 0x6c7471;
    const accent = unlocked ? scene.palette.accent : 0x858b88;
    const g = new Graphics();
    if (scene.climate === "mountain") {
      g.poly([-90, 15, -45, -75, 0, 15]).fill(color);g.poly([-10, 15, 42, -92, 95, 15]).fill(accent);
    } else if (scene.climate === "space") {
      g.circle(-55, -5, 40).fill(color);g.ellipse(-55, -5, 105, 24).stroke({ color: accent, width: 7 });g.circle(45, -30, 13).fill(accent);
    } else if (scene.climate === "sky") {
      g.ellipse(-48, -16, 80, 35).fill(color);g.ellipse(40, -28, 90, 42).fill(accent);g.rect(-8, -72, 20, 68).fill(color);
    } else if (scene.climate === "abyss") {
      g.poly([-90, 15, -45, -60, -15, 5, 25, -88, 90, 15]).fill(color);g.rect(-8, -70, 18, 75).fill(accent);
    } else {
      g.circle(-55, -10, 30).fill(color);g.circle(45, -20, 36).fill(color);g.rect(-8, -75, 18, 80).fill(accent);g.poly([-35, -45, 35, -45, 0, -90]).fill(accent);
    }
    container.addChild(g);
  }

  drawWorldAvatar() {
    const selected = SCENE_BY_CODE.get(this.dashboard.game_state?.selected_map || this.activeMap) || MAP_SCENES[0];
    this.avatar = this.makeAvatar();this.avatar.position.set(selected.world.x, selected.world.y - 125);this.world.addChild(this.avatar);
  }

  enterMap(code, animate = true) {
    const scene = SCENE_BY_CODE.get(code);if (!scene) return;
    const data = this.maps.find(map => map.code === code) || {};
    if (!data.unlocked && this.own) { this.onLockedMap?.(data);return; }
    this.clearScene();this.mode = "region";this.scene = scene;this.activeMap = code;
    this.drawRegionBackdrop(scene);
    this.drawRegionRoutes(scene, data);
    scene.nodes.forEach((item, index) => this.drawRegionNode(scene, data, item, index));
    this.drawPortal(scene, data);
    this.drawCampfire(scene);
    this.avatar = this.makeAvatar();
    const current = scene.nodes.find(item => item.code === this.currentRegion) || scene.entry;
    this.avatar.position.set(current.x, current.y - 46);this.world.addChild(this.avatar);
    this.addParticles(scene.climate, this.particleCount());
    this.fitScene(scene.width, scene.height, animate);
    this.onMapChange?.(code, data);
    this.dispatchMode();
  }

  drawRegionBackdrop(scene) {
    const bg = new Graphics().rect(0, 0, scene.width, scene.height).fill(scene.palette.sky);
    bg.rect(0, 250, scene.width, 650).fill(scene.palette.ground);
    bg.poly([0, 620, 220, 530, 430, 590, 690, 450, 920, 570, 1180, 420, 1600, 520, 1600, 900, 0, 900]).fill({ color: scene.palette.ground2, alpha: .72 });
    this.world.addChild(bg);
    const terrain = new Graphics();
    if (scene.climate === "coast") {
      terrain.rect(0, 690, 1600, 210).fill(scene.palette.water);terrain.ellipse(350, 570, 370, 140).fill(scene.palette.ground2);terrain.ellipse(1050, 520, 520, 190).fill(scene.palette.ground2);
    } else if (scene.climate === "mountain") {
      for (let i = 0; i < 8; i++) terrain.poly([i * 220 - 100, 590, i * 220 + 40, 220 - (i % 3) * 45, i * 220 + 210, 590]).fill({ color: i % 2 ? scene.palette.ground2 : scene.palette.shadow, alpha: .66 });
    } else if (scene.climate === "desert") {
      for (let i = 0; i < 6; i++) terrain.bezierCurveTo(i * 270, 500, i * 270 + 130, 400, i * 270 + 280, 540).stroke({ color: scene.palette.accent, width: 18, alpha: .18 });
      terrain.ellipse(1200, 650, 210, 75).fill(scene.palette.water);
    } else if (scene.climate === "sky") {
      terrain.rect(0, 250, 1600, 650).fill(scene.palette.sky);
      for (let i = 0; i < 7; i++) terrain.ellipse(140 + i * 230, 560 - (i % 3) * 95, 300, 130).fill({ color: scene.palette.ground2, alpha: .92 });
    } else if (scene.climate === "space") {
      terrain.rect(0, 0, 1600, 900).fill(scene.palette.sky);terrain.ellipse(820, 650, 1300, 330).fill(scene.palette.ground);terrain.ellipse(820, 650, 1450, 410).stroke({ color: scene.palette.accent, width: 8, alpha: .26 });
    } else if (scene.climate === "abyss") {
      terrain.rect(0, 0, 1600, 900).fill(scene.palette.sky);terrain.poly([0, 480, 340, 360, 590, 560, 830, 310, 1120, 520, 1600, 300, 1600, 900, 0, 900]).fill(scene.palette.ground);
      terrain.bezierCurveTo(0, 720, 520, 570, 820, 760).bezierCurveTo(1050, 850, 1260, 580, 1600, 690).stroke({ color: scene.palette.accent, width: 22, alpha: .55 });
    } else {
      terrain.bezierCurveTo(0, 720, 420, 580, 690, 720).bezierCurveTo(950, 820, 1270, 590, 1600, 700).stroke({ color: scene.palette.water, width: 75, alpha: .75 });
    }
    this.world.addChild(terrain);
    this.drawDecorations(scene);
  }

  drawDecorations(scene) {
    const g = new Graphics();
    for (let i = 0; i < 28; i++) {
      const x = 45 + (i * 191) % 1510, y = 310 + (i * 137) % 520;
      if (scene.climate === "grassland") { g.rect(x - 4, y, 8, 28).fill(scene.palette.shadow);g.circle(x, y - 8, 19).fill({ color: 0x426b43, alpha: .82 }); }
      else if (scene.climate === "desert") { g.moveTo(x, y).lineTo(x + 16, y - 24).lineTo(x + 31, y).stroke({ color: scene.palette.shadow, width: 5, alpha: .5 }); }
      else if (scene.climate === "space") { g.circle(x, y, 2 + i % 4).fill({ color: scene.palette.accent, alpha: .65 }); }
      else { g.poly([x - 13, y + 10, x, y - 23, x + 15, y + 10]).fill({ color: scene.palette.shadow, alpha: .38 }); }
    }
    this.world.addChild(g);
  }

  drawRegionRoutes(scene, data) {
    const stateMap = this.nodeStateMap;
    const route = new Graphics();
    for (const [aCode, bCode] of scene.routes) {
      const a = scene.nodes.find(item => item.code === aCode), b = scene.nodes.find(item => item.code === bCode);
      const active = Number(stateMap.get(aCode)?.percent || 0) > 0 || Number(stateMap.get(bCode)?.percent || 0) > 0;
      route.moveTo(a.x, a.y).bezierCurveTo((a.x + b.x) / 2, Math.min(a.y, b.y) - 70, (a.x + b.x) / 2, Math.max(a.y, b.y) + 50, b.x, b.y)
        .stroke({ color: active ? scene.palette.accent : 0x5d5b50, width: active ? 12 : 7, alpha: active ? .66 : .38 });
      route.moveTo(a.x, a.y).bezierCurveTo((a.x + b.x) / 2, Math.min(a.y, b.y) - 70, (a.x + b.x) / 2, Math.max(a.y, b.y) + 50, b.x, b.y)
        .stroke({ color: active ? 0xfff3c4 : 0xb1aa93, width: 2, alpha: active ? .75 : .28 });
    }
    this.world.addChild(route);
  }

  drawRegionNode(scene, map, item, index) {
    const region = (map.regions || []).find(value => value.code === item.code) || { code: item.code, name: item.landmark, percent: 0, core: true };
    const computed = this.nodeStateMap.get(item.code) || { state: map.unlocked ? "discovered" : "undiscovered", stars: 0, percent: Number(region.percent || 0) };
    const container = new Container();container.position.set(item.x, item.y);
    const halo = new Graphics().circle(0, 0, 54).fill({ color: stateColor(computed.state, scene), alpha: computed.state === "mastered" ? .35 : .16 });
    const base = new Graphics().ellipse(0, 16, 96, 44).fill({ color: scene.palette.shadow, alpha: .6 });
    const building = drawLandmark(scene, index, computed.state);
    container.addChild(halo, base, building);
    if (computed.state === "mastered") {
      const crown = new Graphics().circle(0, -55, 8).fill(scene.palette.accent);crown.circle(0, -55, 17).stroke({ color: 0xfff0b0, width: 3, alpha: .85 });container.addChild(crown);
    }
    const star = new Text({ text: "★".repeat(Number(computed.stars || 0)) + "☆".repeat(Math.max(0, 4 - Number(computed.stars || 0))), style: new TextStyle({ fill: computed.stars ? 0xffd66b : 0xa7a89f, fontSize: 15, fontFamily: "sans-serif", letterSpacing: 2 }) });
    star.anchor.set(.5);star.position.set(0, 47);container.addChild(star);
    this.world.addChild(container);this.nodeGraphics.set(item.code, container);
    const quest = this.recommendations.find(rec => rec.region_code === item.code && rec.status !== "skipped");
    this.createLabel({ x: item.x, y: item.y + 78, title: region.name || item.landmark, meta: `${Number(region.percent || 0)}% · ${stateText(computed.state)}`, state: computed.state, regionCode: item.code, quest, onClick: () => this.travelTo(item, region, quest) });
  }

  drawPortal(scene, map) {
    const g = new Graphics();
    g.circle(scene.portal.x, scene.portal.y, 52).stroke({ color: map.mastered ? scene.palette.accent : 0x6e716b, width: 12, alpha: .9 });
    g.circle(scene.portal.x, scene.portal.y, 34).fill({ color: map.mastered ? scene.palette.accent : scene.palette.shadow, alpha: .32 });
    g.rect(scene.portal.x - 64, scene.portal.y + 48, 128, 20).fill({ color: scene.palette.shadow, alpha: .85 });
    this.world.addChild(g);
    this.createLabel({ x: scene.portal.x, y: scene.portal.y + 92, title: map.mastered ? "守门人传送门" : "地图守门关", meta: map.mastered ? "可选综合挑战已经开放" : "核心据点全部点亮后开启", state: map.mastered ? "mastered" : "locked", onClick: () => map.mastered ? this.onGuardianSelect?.(map) : this.onLockedMap?.(map) });
  }

  drawCampfire(scene) {
    const temp = Number(this.dashboard.campfire_temperature ?? this.dashboard.summary?.freshness ?? 0);
    const x = scene.entry.x + 35, y = scene.entry.y - 25;
    const g = new Graphics().ellipse(x, y + 23, 70, 24).fill({ color: scene.palette.shadow, alpha: .5 });
    g.poly([x - 18, y + 15, x, y - 35 - temp * .16, x + 19, y + 15]).fill({ color: temp > 35 ? 0xff9c47 : 0xa86b4c, alpha: .9 });
    g.poly([x - 9, y + 10, x, y - 15 - temp * .08, x + 10, y + 10]).fill({ color: 0xffe47c, alpha: temp > 0 ? .9 : .25 });
    this.world.addChild(g);
  }

  makeAvatar() {
    const c = new Container();
    const shadow = new Graphics().ellipse(0, 33, 42, 15).fill({ color: 0x111111, alpha: .3 });
    const body = new Graphics().circle(0, 0, 24).fill(0xf1d28a).stroke({ color: 0x293a31, width: 6 });body.poly([-20, 20, 20, 20, 28, 55, -28, 55]).fill(0x355944).stroke({ color: 0x20392b, width: 5 });
    const mark = new Text({ text: "L", style: new TextStyle({ fill: 0x263d30, fontSize: 23, fontWeight: "800", fontFamily: "serif" }) });mark.anchor.set(.5);mark.position.set(0, 0);
    c.addChild(shadow, body, mark);return c;
  }

  travelTo(item, region, quest) {
    if (!this.own && this.dashboard.spectator_mode) { this.onRegionSelect?.(region, quest);return; }
    if (this.animation || !this.avatar) return;
    const start = { x: this.avatar.x, y: this.avatar.y }, target = { x: item.x, y: item.y - 46 };
    const duration = reducedMotion() ? 1 : clamp(Math.hypot(target.x - start.x, target.y - start.y) * 1.8, 450, 1500);
    this.playSound("walk");
    this.animation = { elapsed: 0, duration, update: t => { const p = ease(t);this.avatar.position.set(lerp(start.x, target.x, p), lerp(start.y, target.y, p) - Math.sin(p * Math.PI * 5) * (reducedMotion() ? 0 : 4)); }, complete: () => {
      this.currentRegion = item.code;this.playSound("node");this.pulseNode(item.code);this.onRegionSelect?.(region, quest);this.onStateChange?.({ selected_map: this.activeMap, selected_region: item.code });
    } };
  }

  pulseNode(code) {
    const target = this.nodeGraphics.get(code);if (!target || reducedMotion()) return;
    let elapsed = 0;const original = target.scale.x;
    const animate = ticker => { elapsed += ticker.deltaMS;const s = original + Math.sin(Math.min(1, elapsed / 500) * Math.PI) * .13;target.scale.set(s);if (elapsed >= 500) { target.scale.set(original);this.app.ticker.remove(animate); } };
    this.app.ticker.add(animate);
  }

  playUnlock(event, replay = false) {
    if (!event) return Promise.resolve();
    this.playSound("unlock");
    const overlay = document.createElement("div");overlay.className = `map-unlock-cinematic ${event.reason === "ability_average" ? "ability-direct" : "mastery-unlock"}`;
    const map = this.maps.find(item => item.code === event.map_code);
    overlay.innerHTML = `<div class="unlock-rays" aria-hidden="true"></div><div class="unlock-seal"><small>${event.reason === "ability_average" ? "ABILITY ROUTE" : "NEW REALM"}</small><b>${escapeHtml(map?.name || event.map_code)}</b><span>${event.reason === "ability_average" ? "高难能力航线已经确认，远征许可永久生效。" : "核心据点的光芒汇入传送门，新领域已经开启。"}</span><em>${event.unlocked_at ? new Date(event.unlocked_at).toLocaleString("zh-CN") : "永久解锁"}</em><button type="button">进入地图</button></div>`;
    this.host.closest(".game-map-shell")?.appendChild(overlay);
    return new Promise(resolve => {
      const done = () => { overlay.classList.add("leaving");setTimeout(() => { overlay.remove();resolve(); }, reducedMotion() ? 50 : 420); };
      overlay.querySelector("button").onclick = () => { if (map?.unlocked) this.enterMap(map.code, true);done(); };
      if (!replay) setTimeout(() => overlay.classList.add("visible"), 30);else overlay.classList.add("visible");
    });
  }

  createLabel({ x, y, title, meta, state, mapCode, regionCode, quest, onClick }) {
    const button = document.createElement("button");button.type = "button";button.className = `game-map-label state-${state}`;
    button.innerHTML = `<span>${escapeHtml(title)}</span><small>${escapeHtml(meta)}</small>${quest ? `<i class="quest-pin quest-${escapeHtml(quest.slot)}">${quest.status === "completed" ? "✓" : "!"}</i>` : ""}`;
    button.dataset.x = x;button.dataset.y = y;if (mapCode) button.dataset.mapCode = mapCode;if (regionCode) button.dataset.regionCode = regionCode;
    button.onclick = event => { event.stopPropagation();onClick?.(); };
    this.labelLayer.appendChild(button);this.labelButtons.push(button);
  }

  bindInput() {
    const canvas = this.app.canvas;canvas.style.touchAction = "none";
    this.onPointerDown = event => { canvas.setPointerCapture?.(event.pointerId);this.pointerMap.set(event.pointerId,{ x:event.clientX,y:event.clientY });if (this.pointerMap.size===1) this.drag={ x:event.clientX,y:event.clientY,cx:this.camera.targetX,cy:this.camera.targetY };else if(this.pointerMap.size===2) this.startPinch(); };
    this.onPointerMove = event => { if(!this.pointerMap.has(event.pointerId))return;this.pointerMap.set(event.pointerId,{x:event.clientX,y:event.clientY});if(this.pointerMap.size===2){this.updatePinch();return;}if(this.drag){this.camera.targetX=this.drag.cx+event.clientX-this.drag.x;this.camera.targetY=this.drag.cy+event.clientY-this.drag.y;this.constrainCamera();} };
    this.onPointerUp = event => { this.pointerMap.delete(event.pointerId);this.drag=null;this.pinch=null;if(this.pointerMap.size===1){const p=[...this.pointerMap.values()][0];this.drag={x:p.x,y:p.y,cx:this.camera.targetX,cy:this.camera.targetY};} };
    this.onWheel = event => { event.preventDefault();const before=this.toWorld(event.clientX,event.clientY);this.camera.targetScale=clamp(this.camera.targetScale*Math.exp(-event.deltaY*.001),.45,1.8);const after=this.toWorld(event.clientX,event.clientY,true);this.camera.targetX+=(after.x-before.x)*this.camera.targetScale;this.camera.targetY+=(after.y-before.y)*this.camera.targetScale;this.constrainCamera(); };
    canvas.addEventListener("pointerdown",this.onPointerDown);canvas.addEventListener("pointermove",this.onPointerMove);canvas.addEventListener("pointerup",this.onPointerUp);canvas.addEventListener("pointercancel",this.onPointerUp);canvas.addEventListener("wheel",this.onWheel,{passive:false});
    this.visibilityHandler=()=>{if(document.hidden)this.app.ticker.stop();else this.app.ticker.start();};document.addEventListener("visibilitychange",this.visibilityHandler);
  }

  startPinch(){const p=[...this.pointerMap.values()];this.pinch={distance:Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y),scale:this.camera.targetScale};}
  updatePinch(){if(!this.pinch)return;const p=[...this.pointerMap.values()];const d=Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y);this.camera.targetScale=clamp(this.pinch.scale*d/Math.max(1,this.pinch.distance),.45,1.8);this.constrainCamera();}
  toWorld(clientX,clientY,target=false){const rect=this.app.canvas.getBoundingClientRect();const c=target?{x:this.camera.targetX,y:this.camera.targetY,scale:this.camera.targetScale}:this.camera;return{x:(clientX-rect.left-c.x)/c.scale,y:(clientY-rect.top-c.y)/c.scale};}

  fitScene(width, height, animate = true) {
    const w=this.host.clientWidth||1000,h=this.host.clientHeight||620;const scale=clamp(Math.min(w/width,h/height)*.92,.45,1.12);
    const x=(w-width*scale)/2,y=(h-height*scale)/2;
    this.camera.targetScale=scale;this.camera.targetX=x;this.camera.targetY=y;
    if(!animate||reducedMotion()){this.camera.scale=scale;this.camera.x=x;this.camera.y=y;}
  }
  zoomBy(factor){this.camera.targetScale=clamp(this.camera.targetScale*factor,.45,1.8);this.constrainCamera();}
  resetCamera(){const size=this.mode==="world"?WORLD_SIZE:this.scene;this.fitScene(size.width,size.height,true);}
  constrainCamera(){const size=this.mode==="world"?WORLD_SIZE:this.scene;if(!size)return;const w=this.host.clientWidth,h=this.host.clientHeight,s=this.camera.targetScale;const pad=90;this.camera.targetX=clamp(this.camera.targetX,Math.min(pad,w-size.width*s-pad),pad);this.camera.targetY=clamp(this.camera.targetY,Math.min(pad,h-size.height*s-pad),pad);}

  addParticles(type,count){if(reducedMotion())return;for(let i=0;i<count;i++){const g=new Graphics().circle(0,0,1.5+(i%3)).fill({color:type==="abyss"?0xff855e:type==="space"?0xe2ccff:0xffffff,alpha:.25+(i%4)*.1});g.position.set((i*283)%1600,(i*157)%900);g.__speed=.018+(i%5)*.008;g.__drift=(i%2?1:-1)*.011;this.particles.push(g);this.world.addChild(g);}}
  particleCount(){if(this.effectsQuality==="low"||innerWidth<700)return 10;return this.effectsQuality==="high"?46:26;}

  tick(deltaMS){
    if(this.destroyed)return;const smoothing=reducedMotion()?1:1-Math.pow(.001,deltaMS/1000);
    this.camera.x=lerp(this.camera.x,this.camera.targetX,smoothing);this.camera.y=lerp(this.camera.y,this.camera.targetY,smoothing);this.camera.scale=lerp(this.camera.scale,this.camera.targetScale,smoothing);
    this.world.position.set(this.camera.x,this.camera.y);this.world.scale.set(this.camera.scale);
    this.updateLabels();
    for(const p of this.particles){p.y-=deltaMS*p.__speed;p.x+=deltaMS*p.__drift;if(p.y<-20)p.y=920;if(p.x<0)p.x=1600;if(p.x>1600)p.x=0;}
    if(this.animation){this.animation.elapsed+=deltaMS;const t=Math.min(1,this.animation.elapsed/this.animation.duration);this.animation.update(t);if(t>=1){const done=this.animation.complete;this.animation=null;done?.();}}
  }

  updateLabels(){for(const button of this.labelButtons){const x=Number(button.dataset.x)*this.camera.scale+this.camera.x,y=Number(button.dataset.y)*this.camera.scale+this.camera.y;button.style.transform=`translate3d(${x}px,${y}px,0) translate(-50%,0) scale(${clamp(this.camera.scale,.72,1.05)})`;button.classList.toggle("offscreen",x<-180||y<-100||x>this.host.clientWidth+180||y>this.host.clientHeight+100);}}
  dispatchMode(){this.host.dispatchEvent(new CustomEvent("training-map-mode",{detail:{mode:this.mode,map:this.activeMap}}));}

  setAudio(enabled){this.audioEnabled=Boolean(enabled);this.onStateChange?.({audio_enabled:this.audioEnabled});return this.audioEnabled;}
  playSound(type){if(!this.audioEnabled)return;try{this.audioContext??=new AudioContext();const o=this.audioContext.createOscillator(),g=this.audioContext.createGain();const freq={walk:170,node:420,complete:620,unlock:280}[type]||300;o.frequency.setValueAtTime(freq,this.audioContext.currentTime);if(type==="unlock")o.frequency.exponentialRampToValueAtTime(740,this.audioContext.currentTime+.42);g.gain.setValueAtTime(.035,this.audioContext.currentTime);g.gain.exponentialRampToValueAtTime(.001,this.audioContext.currentTime+(type==="unlock"?.55:.16));o.connect(g).connect(this.audioContext.destination);o.start();o.stop(this.audioContext.currentTime+(type==="unlock"?.56:.17));}catch{}}
  async toggleFullscreen(){if(document.fullscreenElement)await document.exitFullscreen();else await this.host.closest(".game-map-shell")?.requestFullscreen?.();}

  destroy(){this.destroyed=true;this.host?.classList.remove("is-ready");this.shell?.classList.remove("is-ready");const c=this.app?.canvas;if(c){c.removeEventListener("pointerdown",this.onPointerDown);c.removeEventListener("pointermove",this.onPointerMove);c.removeEventListener("pointerup",this.onPointerUp);c.removeEventListener("pointercancel",this.onPointerUp);c.removeEventListener("wheel",this.onWheel);}document.removeEventListener("visibilitychange",this.visibilityHandler);this.labelLayer.replaceChildren();this.audioContext?.close?.();this.app?.destroy(true,{children:true,texture:true});}
}

function drawLandmark(scene,index,state){
  const active=state!=="undiscovered"&&state!=="discovered",mastered=state==="mastered";const wall=active?scene.palette.ground2:0x777b74,roof=mastered?scene.palette.accent:active?scene.palette.shadow:0x585d58;
  const g=new Graphics();
  if(index%4===0){g.rect(-29,-27,58,55).fill(wall).stroke({color:roof,width:5});g.poly([-38,-25,0,-63,38,-25]).fill(roof);g.rect(-8,1,16,27).fill(scene.palette.shadow);}
  else if(index%4===1){g.rect(-22,-48,44,72).fill(wall).stroke({color:roof,width:5});g.circle(0,-47,25).stroke({color:roof,width:8});g.rect(-6,-80,12,30).fill(roof);}
  else if(index%4===2){g.poly([-42,22,-30,-36,0,-60,31,-36,43,22]).fill(wall).stroke({color:roof,width:5});g.circle(0,-15,12).fill(roof);}
  else{g.rect(-36,-20,72,46).fill(wall).stroke({color:roof,width:5});g.rect(-21,-52,42,34).fill(roof);g.rect(-7,-10,14,36).fill(scene.palette.shadow);}
  if(mastered){g.rect(24,-72,4,48).fill(0xf3ddb0);g.poly([28,-72,58,-62,28,-50]).fill(scene.palette.accent);}
  return g;
}
function stateColor(state,scene){return({undiscovered:0x555a58,discovered:0x8b8f88,in_progress:scene.palette.accent,strong:0xe5c86c,mastered:0xffe189})[state]||scene.palette.accent;}
function stateText(state){return({undiscovered:"尚未发现",discovered:"待探索",in_progress:"修复中",strong:"优势据点",mastered:"完全点亮"})[state]||"待探索";}
function escapeHtml(value){return String(value??"").replace(/[&<>'"]/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[char]);}
