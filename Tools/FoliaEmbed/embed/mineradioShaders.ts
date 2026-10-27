// 粒子着色器移植自 Mineradio（GPL-3.0，https://github.com/XxHuberrr/Mineradio）的
// public/js/modules/02-visual/00-pointer-cover-particles.js：保留各预设的造型和配色，
// 去掉鼠标、手势、AI 深度、涟漪纹理等 App 里用不到的输入。预设编号和原版一致。

const NOISE = /* glsl */ `
#define PI 3.14159265359

vec3 mod289(vec3 x){return x-floor(x*(1.0/289.0))*289.0;}
vec4 mod289v(vec4 x){return x-floor(x*(1.0/289.0))*289.0;}
vec4 perm(vec4 x){return mod289v(((x*34.0)+1.0)*x);}
float snoise(vec3 v){
  const vec2 C=vec2(1.0/6.0,1.0/3.0);
  const vec4 D=vec4(0.0,0.5,1.0,2.0);
  vec3 i=floor(v+dot(v,C.yyy));
  vec3 x0=v-i+dot(i,C.xxx);
  vec3 g=step(x0.yzx,x0.xyz); vec3 l=1.0-g;
  vec3 i1=min(g.xyz,l.zxy); vec3 i2=max(g.xyz,l.zxy);
  vec3 x1=x0-i1+C.xxx;
  vec3 x2=x0-i2+C.yyy;
  vec3 x3=x0-D.yyy;
  i=mod289(i);
  vec4 p=perm(perm(perm(i.z+vec4(0.0,i1.z,i2.z,1.0))+i.y+vec4(0.0,i1.y,i2.y,1.0))+i.x+vec4(0.0,i1.x,i2.x,1.0));
  float n_=0.142857142857;
  vec3 ns=n_*D.wyz-D.xzx;
  vec4 j=p-49.0*floor(p*ns.z*ns.z);
  vec4 x_=floor(j*ns.z); vec4 y_=floor(j-7.0*x_);
  vec4 x=x_*ns.x+ns.yyyy; vec4 y=y_*ns.x+ns.yyyy;
  vec4 h=1.0-abs(x)-abs(y);
  vec4 b0=vec4(x.xy,y.xy); vec4 b1=vec4(x.zw,y.zw);
  vec4 s0=floor(b0)*2.0+1.0; vec4 s1=floor(b1)*2.0+1.0;
  vec4 sh=-step(h,vec4(0.0));
  vec4 a0=b0.xzyw+s0.xzyw*sh.xxyy; vec4 a1=b1.xzyw+s1.xzyw*sh.zzww;
  vec3 p0=vec3(a0.xy,h.x); vec3 p1=vec3(a0.zw,h.y); vec3 p2=vec3(a1.xy,h.z); vec3 p3=vec3(a1.zw,h.w);
  vec4 norm=inversesqrt(vec4(dot(p0,p0),dot(p1,p1),dot(p2,p2),dot(p3,p3)));
  p0*=norm.x; p1*=norm.y; p2*=norm.z; p3*=norm.w;
  vec4 m=max(0.6-vec4(dot(x0,x0),dot(x1,x1),dot(x2,x2),dot(x3,x3)),0.0);
  m=m*m;
  return 42.0*dot(m*m,vec4(dot(p0,x0),dot(p1,x1),dot(p2,x2),dot(p3,x3)));
}

float hash11(float p) {
  return fract(sin(p * 127.1) * 43758.5453123);
}
`;

const PARTICLE_VERTEX = /* glsl */ `
uniform float uTime, uBass, uMid, uTreble, uBeat, uEnergy, uBurstAmt;
uniform float uPreset, uIntensity, uSpeed, uVinylSpin, uColorBoost;
uniform float uHasCover, uPixel, uColorMixT, uSizeScale;
uniform sampler2D uCoverTex, uPrevCoverTex;
attribute vec2 aUv;
attribute float aRand;
varying vec3 vColor;
varying float vBright, vRipple, vAlpha;

${NOISE}

vec2 safeCoverUv(vec2 uv) {
  return clamp(uv, vec2(0.0012), vec2(0.9988));
}

vec3 sampleNewCoverColor(vec2 uv) {
  return texture2D(uCoverTex, safeCoverUv(uv)).rgb;
}

vec3 samplePrevCoverColor(vec2 uv) {
  return texture2D(uPrevCoverTex, safeCoverUv(uv)).rgb;
}

void main(){
  float t = uTime * uSpeed;
  vec3 pos = position;
  vec2 sampleUv = safeCoverUv(aUv);
  vec3 newCol = sampleNewCoverColor(sampleUv);
  vec3 prevCol = samplePrevCoverColor(sampleUv);
  vec3 coverColor = mix(prevCol, newCol, clamp(uColorMixT, 0.0, 1.0));
  float maxRippleAmp = 0.0;

  vec3 defaultColor = mix(
    vec3(0.36, 0.28, 0.72),
    mix(vec3(0.85, 0.55, 0.95), vec3(0.45, 0.78, 0.95), aUv.x),
    aUv.y
  );
  vColor = mix(defaultColor, coverColor, uHasCover);
  vAlpha = 1.0;

  float K = uIntensity * 1.6;

  // Preset 0: 封面（丝绸）——封面铺成粒子平面，随中低频起伏
  if (uPreset < 0.5) {
    pos = position;
    float midN = snoise(vec3(pos.x*1.4, pos.y*1.4, t*0.55)) * 0.6
               + snoise(vec3(pos.x*2.8+5.0, pos.y*2.8-3.0, t*0.85)) * 0.4;
    float midMask = 0.55 + 0.45 * snoise(vec3(pos.x*0.4, pos.y*0.4, t*0.18));
    float midDisp = midN * uMid * 0.55 * midMask * K;
    float trebleJ = snoise(vec3(pos.x*6.5, pos.y*6.5, t*3.5 + aRand*4.0)) * uTreble * 0.18 * K;
    float bassBreath = snoise(vec3(pos.x*0.35, pos.y*0.35, t*0.4)) * uBass * 0.42 * K;
    // 原版的点击涟漪换成跟着歌词节拍的一圈波纹
    float d = length(pos.xy);
    float ring = exp(-pow((d - (1.0 - uBeat) * 3.2) / 0.55, 2.0)) * uBeat;
    pos.z = midDisp + trebleJ + bassBreath + ring * 0.42 * K;
    maxRippleAmp = ring * 0.6;
  }

  // Preset 1: 滚筒——封面卷成隧道，缓慢自旋向前流动
  else if (uPreset < 1.5) {
    float spin = t * 0.12;
    float angle = aUv.x * 2.0 * PI + spin;
    float flow = aUv.y - t * 0.08 * (1.0 + uBass * 0.55);
    flow = fract(flow);
    float zPos = (flow - 0.5) * 9.0;
    float baseR = 2.0 - uBass * 0.28 * K;
    float ripG = sin(angle * 5.0 + zPos * 1.4 + t * 2.2) * 0.10 * (uMid + uTreble) * K;
    float r = baseR + ripG;
    pos.x = cos(angle) * r;
    pos.y = sin(angle) * r;
    pos.z = zPos;

    sampleUv = safeCoverUv(vec2(aUv.x, flow));
    newCol = sampleNewCoverColor(sampleUv);
    prevCol = samplePrevCoverColor(sampleUv);
    coverColor = mix(prevCol, newCol, clamp(uColorMixT, 0.0, 1.0));
    vColor = mix(defaultColor, coverColor, uHasCover);

    float depthFade = smoothstep(-4.5, 4.5, zPos);
    vColor *= 0.4 + depthFade * 0.7;
  }

  // Preset 2: 星球——封面包成自转的球体，高频时表面迸发
  else if (uPreset < 2.5) {
    float theta = aUv.x * 2.0 * PI;
    float phi = (aUv.y - 0.5) * PI;
    float baseR = 2.2;
    float trebFlare = snoise(vec3(theta * 1.5, phi * 1.5, t * 0.7)) * uTreble * 0.85 * K;
    float bassExpand = uBass * 0.35 * K;
    float r = baseR * (1.0 + bassExpand) + trebFlare;

    pos.x = r * cos(phi) * cos(theta);
    pos.y = r * sin(phi);
    pos.z = r * cos(phi) * sin(theta);

    float yaw = t * 0.18;
    float cy = cos(yaw), sy = sin(yaw);
    pos.xz = mat2(cy, -sy, sy, cy) * pos.xz;
  }

  // Preset 4: 唱片——圆形封面在中间，外圈是黑胶纹路和白色粒子边
  else if (uPreset < 4.5) {
    float bassDrive = smoothstep(0.08, 0.78, uBass + uBeat * 0.82);
    float highDrive = smoothstep(0.05, 0.46, uTreble);

    vec2 p = (aUv - 0.5) * 5.12;
    float spin = uVinylSpin;
    float cs = cos(spin), sn = sin(spin);
    vec2 rp = mat2(cs, -sn, sn, cs) * p;
    float d = length(p);
    float angle0 = atan(p.y, p.x);
    float recordR = 2.46;
    float coverR = 1.18;
    float recordAlpha = 1.0 - smoothstep(recordR - 0.02, recordR + 0.05, d);
    float coverMask = 1.0 - smoothstep(coverR - 0.012, coverR + 0.018, d);
    float border = exp(-pow((d - coverR) / 0.064, 2.0));
    float outerRim = exp(-pow((d - (recordR - 0.050)) / 0.055, 2.0));
    float vinylN = clamp((d - coverR) / max(0.001, recordR - coverR), 0.0, 1.0);

    pos = vec3(rp * (1.0 + bassDrive * 0.012 + uBeat * 0.026), 0.0);
    vAlpha = recordAlpha;

    if (coverMask > 0.02) {
      vec2 coverUv = p / (coverR * 2.0) + 0.5;
      newCol = sampleNewCoverColor(coverUv);
      prevCol = samplePrevCoverColor(coverUv);
      coverColor = mix(prevCol, newCol, clamp(uColorMixT, 0.0, 1.0));
      vColor = mix(defaultColor, coverColor, uHasCover);
      float coverShade = 1.02 + 0.10 * (1.0 - smoothstep(0.0, coverR, d));
      vColor *= coverShade;
      vColor = mix(vColor, vec3(1.0), border * 0.54);
      pos.z = 0.040 + border * 0.026 + uBeat * 0.018;
      maxRippleAmp = max(maxRippleAmp, border * 0.30 + bassDrive * 0.075 + uBeat * 0.075);
    } else {
      float groove = 0.5 + 0.5 * sin((d - coverR) * 98.0);
      float fineGroove = 0.5 + 0.5 * sin((d - coverR) * 170.0 + aRand * 3.0);
      float tick = smoothstep(0.82, 0.995, hash11(floor((angle0 + PI) * 38.0) + floor(d * 72.0) * 2.1));
      vec3 vinyl = vec3(0.052, 0.054, 0.058) + vec3(0.052) * groove + vec3(0.026) * fineGroove;
      vinyl = mix(vinyl, coverColor * 0.32, 0.18 * (1.0 - vinylN));
      float whiteRing = max(border * 0.92, outerRim * 0.26);
      vColor = mix(vinyl, vec3(0.92, 0.94, 0.94), whiteRing);
      vColor = mix(vColor, vec3(1.0), tick * highDrive * (0.06 + border * 0.12));
      pos.z = groove * 0.010 + border * 0.024 + bassDrive * vinylN * 0.016 * K + tick * highDrive * 0.010;
      maxRippleAmp = max(maxRippleAmp, border * 0.32 + outerRim * 0.12 + bassDrive * vinylN * 0.11 + tick * highDrive * 0.10 + uBeat * vinylN * 0.08);
    }
  }

  // Preset 5: 星河——极光丝带、纵深星尘和封面色的音乐流
  else if (uPreset < 8.5) {
    float bassGlow = smoothstep(0.07, 0.78, uBass) * 0.34 + uBeat * 0.014;
    float midGlow = smoothstep(0.07, 0.62, uMid) * 0.42;
    float highGlow = smoothstep(0.04, 0.46, uTreble) * 0.46;
    float lane = aUv.y;
    float transition = clamp(uBurstAmt, 0.0, 1.0);

    if (lane < 0.80) {
      float laneWarp = snoise(vec3(aUv.x * 0.42, lane * 1.7, t * 0.026)) * 0.11 + (hash11(aRand * 73.1) - 0.5) * 0.045;
      float warpedLane = clamp(lane + laneWarp, 0.0, 0.80);
      float bandCoord = warpedLane / 0.80 * 5.65 + snoise(vec3(aUv.x * 0.82, lane * 2.25, t * 0.032)) * 0.62;
      float band = floor(bandCoord);
      float local = fract(bandCoord + hash11(band * 9.13 + aRand * 2.4) * 0.18);
      float bandN = clamp((band + 0.5) / 5.65, 0.0, 1.0);
      float seed = hash11(band * 19.17 + aRand * 31.0);
      float flow = fract(aUv.x + t * (0.0034 + bandN * 0.0038 + seed * 0.0022) + seed * 0.53);
      float arc = (flow - 0.5) * PI * (1.35 + bandN * 0.72 + seed * 0.24);
      float armCurve = sin(arc + bandN * 2.2 + seed * 5.3);
      float spiralRadius = 9.2 + bandN * 11.8 + seed * 6.0 + local * 2.9;
      float x = cos(arc * 0.72 + bandN * 0.92 + seed * 1.3) * spiralRadius + (flow - 0.5) * (13.5 + bandN * 9.5);
      float ribbonPhase = flow * PI * 2.0 * (0.55 + bandN * 0.24 + seed * 0.10) + t * (0.010 + bandN * 0.007) + seed * 5.7;
      float broadWave = sin(ribbonPhase) * 0.92;
      float fineWave = sin(ribbonPhase * (1.36 + seed * 0.62) - t * 0.044 + seed * 5.0) * 0.045;
      float yBase = (bandN - 0.5) * 13.2 + armCurve * (2.3 + bandN * 1.6) + (seed - 0.5) * 1.85 + snoise(vec3(bandN * 2.0, flow * 0.62, seed)) * 0.92;
      float ridgeCenter = 0.43 + (seed - 0.5) * 0.18;
      float ridge = exp(-pow((local - ridgeCenter) / (0.25 + seed * 0.04), 2.0));
      float softMask = smoothstep(0.010, 0.12, lane) * (1.0 - smoothstep(0.72, 0.81, lane));
      float ribbonNoise = snoise(vec3(flow * 1.18 + seed, bandN * 2.0, t * 0.018)) * 0.74;
      float zLayer = mix(-23.5, 15.5, bandN) + (seed - 0.5) * 6.0;

      pos.x = x + ribbonNoise * 1.40 + sin(t * 0.012 + seed * 8.0) * 0.22;
      pos.y = yBase + broadWave + fineWave + (local - 0.5) * (0.58 + ridge * 0.14);
      pos.z = zLayer + broadWave * 1.35 + ribbonNoise * 1.85;

      float pulseLine = 0.5 + 0.5 * sin(ribbonPhase * (1.7 + seed * 0.9) - t * 0.32 + seed * 6.0);
      vec3 aurora = mix(vec3(0.52, 0.86, 1.0), vec3(0.70, 0.58, 1.0), bandN);
      aurora = mix(aurora, vec3(0.96, 0.98, 0.92), bassGlow * 0.05);
      vAlpha = (0.18 + ridge * 0.78 + pulseLine * highGlow * 0.035 + bassGlow * 0.025) * softMask * (0.96 + transition * 0.02);
      vColor = mix(coverColor, aurora, 0.62 + ridge * 0.22) * (0.76 + ridge * 0.86 + pulseLine * highGlow * 0.05 + bassGlow * 0.04);
      maxRippleAmp = max(maxRippleAmp, ridge * (0.12 + midGlow * 0.05) + pulseLine * highGlow * 0.045 + bassGlow * 0.030);
    } else {
      float q = (lane - 0.80) / 0.20;
      float seed = hash11(aRand * 917.0 + floor(q * 130.0));
      float depth = mix(-32.0, 18.0, seed);
      float drift = fract(aUv.x + t * (0.0014 + seed * 0.0048) + seed * 0.63);
      float cluster = snoise(vec3(seed * 2.0, q * 3.2, t * 0.007));
      float x = (drift - 0.5) * (45.0 + seed * 22.0) + cluster * 3.4;
      float y = (hash11(aRand * 331.0 + seed * 5.0) - 0.5) * 22.0 + sin(t * (0.018 + seed * 0.028) + seed * 7.0) * 0.86;
      float z = depth + sin(t * (0.020 + seed * 0.032) + aRand * 8.0) * 1.05;
      float twinkle = pow(0.5 + 0.5 * sin(t * (0.24 + seed * 0.42) + aRand * 17.0), 5.0);
      float dust = smoothstep(0.22, 0.98, hash11(aRand * 661.0 + floor(q * 160.0)));

      pos = vec3(x, y, z);
      vAlpha = dust * (0.16 + twinkle * 0.46 + highGlow * 0.025 + bassGlow * 0.018) * (1.0 - q * 0.06);
      vColor = mix(coverColor, vec3(0.92, 0.97, 1.0), 0.62 + twinkle * 0.14) * (0.72 + twinkle * 0.62 + bassGlow * 0.025);
      maxRippleAmp = max(maxRippleAmp, twinkle * highGlow * 0.055 + dust * bassGlow * 0.030);
    }

    if (transition > 0.001) {
      float bloom = smoothstep(0.0, 1.0, transition);
      vec2 burstVec = pos.xy + vec2(hash11(aRand * 31.0) - 0.5, hash11(aRand * 47.0) - 0.5) * 0.75;
      vec2 burstDir = burstVec / max(length(burstVec), 0.001);
      pos.xy += burstDir * bloom * 0.026;
      pos.xy += vec2(snoise(vec3(aRand, t * 0.014, 1.0)), snoise(vec3(aRand, t * 0.014, 5.0))) * bloom * 0.06;
      pos.xy *= 1.0 + bloom * 0.014;
      pos.z += (hash11(aRand * 123.0) - 0.5) * bloom * 0.18;
      vAlpha *= 0.86 + bloom * 0.22;
      maxRippleAmp = max(maxRippleAmp, bloom * 0.10);
    }
  }

  // Preset 9: 月蚀圣环——黑曜轨道、冷金日冕
  else if (uPreset < 9.5) {
    float ringIndex = floor(aUv.y * 8.0);
    float ringLocal = fract(aUv.y * 8.0);
    float ringN = (ringIndex + 0.5) / 8.0;
    float ringSeed = hash11(ringIndex * 19.73 + 2.1);
    float theta = aUv.x * 2.0 * PI + ringIndex * 0.47 + t * (0.035 + ringN * 0.026);
    float eclipseDrive = smoothstep(0.06, 0.76, uBass) * 0.17 + uBeat * 0.08;
    float ridge = exp(-pow((ringLocal - 0.5) / (0.17 + ringSeed * 0.045), 2.0));
    float radius = 0.92 + ringN * 3.18 + (ringLocal - 0.5) * 0.24 + eclipseDrive * (0.18 + ringN * 0.34);
    float eccentric = 0.49 + ringN * 0.20;
    float xh = cos(theta) * radius * (1.18 + ringN * 0.10);
    float yh = sin(theta) * radius * eccentric;
    float zh = (ringN - 0.5) * 1.34 + sin(theta * 2.0 + ringSeed * 6.0) * (0.10 + ringN * 0.09);
    float tilt = -0.34 + ringN * 0.72;
    float ct = cos(tilt), st = sin(tilt);
    pos = vec3(xh, yh * ct - zh * st, yh * st + zh * ct);

    vec3 coldRim = vec3(0.48, 0.82, 1.0);
    vec3 antiqueGold = vec3(0.93, 0.72, 0.38);
    vec3 haloColor = mix(coldRim, antiqueGold, smoothstep(0.18, 0.84, ringN + sin(theta) * 0.08));
    haloColor = mix(haloColor, vec3(0.98, 0.96, 0.88), ridge * (0.28 + uTreble * 0.18));
    vColor = mix(coverColor * 0.72, haloColor, 0.62 + ridge * 0.20);
    float corona = pow(0.5 + 0.5 * sin(theta * (13.0 + ringIndex) - t * 0.52 + ringSeed * 9.0), 8.0);
    vAlpha = (0.18 + ridge * 0.74 + corona * (0.08 + uTreble * 0.18)) * smoothstep(0.02, 0.14, aUv.y) * (1.0 - smoothstep(0.93, 1.0, aUv.y));
    maxRippleAmp = max(maxRippleAmp, ridge * (0.12 + eclipseDrive * 0.20) + corona * uTreble * 0.13);
  }

  // Preset 10: 雨幕霓虹——城市雨丝、色谱残光
  else if (uPreset < 10.5) {
    float column = floor(aUv.x * 52.0);
    float columnN = (column + 0.5) / 52.0;
    float columnLocal = fract(aUv.x * 52.0);
    float rainSeed = hash11(column * 41.17 + floor(columnLocal * 5.0) * 7.9);
    float rainSpeed = 0.026 + rainSeed * 0.052 + smoothstep(0.08, 0.76, uBass) * 0.014;
    float fall = fract(1.0 - aUv.y + t * rainSpeed + rainSeed * 0.87);
    float xRain = (columnN - 0.5) * 11.8 + (columnLocal - 0.5) * 0.11;
    float yRain = (0.5 - fall) * 8.8;
    float cityDepth = mix(-3.8, 2.6, hash11(column * 11.3 + 0.7));
    float wind = sin(t * 0.17 + column * 0.63 + fall * 3.4) * (0.08 + rainSeed * 0.12);
    float perspective = 0.76 + smoothstep(-3.8, 2.6, cityDepth) * 0.34;
    pos = vec3((xRain + wind) * perspective, yRain, cityDepth + sin(fall * PI * 2.0 + rainSeed * 7.0) * 0.05);

    float dash = pow(0.5 + 0.5 * sin(fall * (52.0 + rainSeed * 38.0) - t * 0.32), 10.0);
    float dropHead = pow(0.5 + 0.5 * sin(fall * 17.0 + rainSeed * 12.0), 18.0);
    vec3 neonA = vec3(0.20, 0.88, 1.0);
    vec3 neonB = vec3(1.0, 0.26, 0.63);
    vec3 neonC = vec3(1.0, 0.72, 0.30);
    vec3 rainColor = mix(neonA, neonB, smoothstep(0.18, 0.78, rainSeed));
    rainColor = mix(rainColor, neonC, smoothstep(0.84, 0.99, rainSeed));
    vColor = mix(coverColor * 0.82, rainColor, 0.58 + dash * 0.18);
    vAlpha = 0.09 + dash * 0.40 + dropHead * (0.22 + uTreble * 0.30);
    vAlpha *= 0.58 + perspective * 0.42;
    pos.x += dropHead * sin(t * 0.8 + rainSeed * 8.0) * uTreble * 0.055;
    maxRippleAmp = max(maxRippleAmp, dash * uMid * 0.10 + dropHead * (0.10 + uTreble * 0.22));
  }

  // Preset 11: 折光蝶群——折纸翼阵、光谱迁徙
  else if (uPreset < 11.5) {
    float flockIndex = floor(aUv.y * 12.0);
    float wingY = fract(aUv.y * 12.0) * 2.0 - 1.0;
    float wingX = aUv.x * 2.0 - 1.0;
    float flockSeed = hash11(flockIndex * 23.73 + 4.0);
    float gx = mod(flockIndex, 3.0) - 1.0;
    float gy = floor(flockIndex / 3.0) - 1.5;
    float migrate = t * (0.018 + flockSeed * 0.018);
    vec2 flockCenter = vec2(gx * 2.42 + sin(migrate + flockSeed * 8.0) * 0.48,
                            gy * 2.10 + cos(migrate * 0.83 + flockSeed * 9.0) * 0.36);
    float ax = abs(wingX);
    float wingMask = 1.0 - smoothstep(0.72, 1.18, abs(wingY) + ax * 0.38);
    float bodyMask = exp(-pow(wingX / 0.075, 2.0)) * (1.0 - smoothstep(0.62, 1.0, abs(wingY)));
    float flap = sin(t * (0.72 + flockSeed * 0.35) + flockIndex * 1.7) * (0.34 + uMid * 0.42 + uBeat * 0.16);
    float lx = sign(wingX) * (0.12 + pow(ax, 0.76) * 0.88);
    float ly = wingY * (0.48 + (1.0 - ax) * 0.22);
    float lz = ax * (0.42 + flap) + (1.0 - abs(wingY)) * 0.08;
    float heading = -0.20 + (flockSeed - 0.5) * 0.70;
    float ch = cos(heading), sh = sin(heading);
    vec2 folded = mat2(ch, -sh, sh, ch) * vec2(lx, ly);
    pos = vec3(flockCenter + folded, (flockSeed - 0.5) * 3.4 + lz);

    vec3 prismLeft = vec3(0.42, 0.94, 0.82);
    vec3 prismRight = vec3(0.96, 0.62, 0.92);
    vec3 prism = mix(prismLeft, prismRight, smoothstep(-0.8, 0.8, wingX));
    prism = mix(prism, vec3(1.0, 0.91, 0.64), smoothstep(0.72, 1.0, ax));
    vColor = mix(coverColor * 0.78, prism, 0.60 + wingMask * 0.18);
    vAlpha = wingMask * (0.22 + (1.0 - ax) * 0.42 + uTreble * 0.16) + bodyMask * 0.68;
    maxRippleAmp = max(maxRippleAmp, wingMask * (0.07 + abs(flap) * 0.12) + bodyMask * uBass * 0.12);
  }

  // Preset 12: 深海绽放——生物荧光、潮汐花冠
  else {
    float bloomR = pow(aUv.y, 0.72);
    float bloomTheta = aUv.x * 2.0 * PI + bloomR * 0.72 + t * 0.018;
    float petalWave = 0.5 + 0.5 * cos(bloomTheta * 9.0 - bloomR * 3.8);
    float bloomDrive = smoothstep(0.06, 0.74, uBass) * 0.26 + uBeat * 0.10;
    float radiusBloom = bloomR * (3.30 + bloomDrive) * (0.78 + petalWave * 0.34);
    float petalFold = sin(bloomTheta * 9.0 - bloomR * 5.4 + t * 0.13);
    float bowl = (1.0 - bloomR) * 1.12 - bloomR * bloomR * 0.52;
    pos.x = cos(bloomTheta) * radiusBloom;
    pos.y = sin(bloomTheta) * radiusBloom * 0.82;
    pos.z = bowl + petalFold * (0.13 + bloomR * 0.47) + sin(bloomTheta * 3.0 + t * 0.07) * 0.08;
    float bloomTilt = -0.30;
    float cb = cos(bloomTilt), sb = sin(bloomTilt);
    pos.yz = mat2(cb, -sb, sb, cb) * pos.yz;

    vec3 abyss = vec3(0.12, 0.58, 0.56);
    vec3 violet = vec3(0.38, 0.32, 0.95);
    vec3 pearl = vec3(0.82, 1.0, 0.94);
    vec3 bloomColor = mix(abyss, violet, smoothstep(0.18, 0.88, bloomR + petalWave * 0.10));
    float luminousEdge = smoothstep(0.64, 0.98, bloomR) * (0.55 + petalWave * 0.45);
    bloomColor = mix(bloomColor, pearl, luminousEdge * (0.32 + uTreble * 0.22));
    vColor = mix(coverColor * 0.72, bloomColor, 0.68);
    float filament = pow(0.5 + 0.5 * sin(bloomTheta * 18.0 + bloomR * 19.0 - t * 0.26), 7.0);
    vAlpha = (0.16 + petalWave * 0.31 + filament * 0.26 + luminousEdge * 0.30) * smoothstep(0.01, 0.10, bloomR);
    maxRippleAmp = max(maxRippleAmp, petalWave * bloomDrive * 0.18 + filament * uTreble * 0.17 + luminousEdge * uMid * 0.09);
  }

  vColor = pow(max(vColor, vec3(0.0)), vec3(1.0 / max(0.35, uColorBoost)));

  vBright = 0.82 + maxRippleAmp * 0.55 + uBass * 0.10 + uEnergy * 0.05 + uBurstAmt * 0.40;
  if (uPreset > 4.5) {
    vBright = 0.94 + maxRippleAmp * 0.34 + uBass * 0.020 + uEnergy * 0.026 + uBurstAmt * 0.025;
    if (uPreset > 8.5) vBright = 0.86 + maxRippleAmp * 0.52 + uEnergy * 0.045 + uBeat * 0.055;
  } else if (uPreset > 3.5) {
    vBright = 0.94 + maxRippleAmp * 0.64 + uBass * 0.08 + uEnergy * 0.05 + uBeat * 0.16 + uBurstAmt * 0.16;
  }
  vRipple = clamp(maxRippleAmp * 1.5, 0.0, 1.0);

  vec4 mvPos = modelViewMatrix * vec4(pos, 1.0);
  float depthSize = 36.0 / max(0.5, -mvPos.z);
  float audioBoost = 1.0 + maxRippleAmp * 0.7 + uBeat * 0.30 + uBurstAmt * 0.5;
  float sz = clamp(depthSize * audioBoost, 1.05, 4.95);
  if (uPreset > 4.5) {
    float flowDrive = uBass * 0.070 + uMid * 0.046 + uTreble * 0.060 + uBurstAmt * 0.090 + uBeat * 0.055;
    sz = clamp(depthSize * (1.05 + flowDrive), 1.00, 5.45);
    if (uPreset > 8.5) {
      float authoredDrive = uBass * 0.10 + uMid * 0.08 + uTreble * 0.12 + uBeat * 0.10;
      sz = clamp(depthSize * (0.98 + authoredDrive), 1.00, 4.85);
    }
  } else if (uPreset > 3.5) {
    float ringDrive = uBass * 0.30 + uMid * 0.18 + uTreble * 0.22 + uBeat * 0.30;
    sz = clamp(depthSize * (0.90 + ringDrive * 0.62), 1.05, 3.90);
  }
  gl_PointSize = sz * uPixel * uSizeScale;
  gl_Position = projectionMatrix * mvPos;
}
`;

export const particleVertexShader = PARTICLE_VERTEX;

export const bloomVertexShader = PARTICLE_VERTEX
    .replace('uniform float uHasCover, uPixel, uColorMixT, uSizeScale;', 'uniform float uHasCover, uPixel, uColorMixT, uSizeScale, uBloomSize;')
    .replace('gl_PointSize = sz * uPixel * uSizeScale;', 'gl_PointSize = sz * uPixel * uSizeScale * uBloomSize;');

export const particleFragmentShader = /* glsl */ `
uniform sampler2D uDotTex;
uniform float uAlpha;
varying vec3 vColor;
varying float vBright, vRipple, vAlpha;

void main(){
  vec4 tex = texture2D(uDotTex, gl_PointCoord);
  if (tex.a < 0.02) discard;
  vec3 col = vColor * vBright;
  col = mix(col, col * 1.2, vRipple * 0.4);
  col = clamp(col, vec3(0.0), vec3(1.6));
  gl_FragColor = vec4(col, tex.a * uAlpha * vAlpha);
}
`;

export const bloomFragmentShader = /* glsl */ `
uniform sampler2D uDotTex;
uniform float uAlpha, uBloomStrength;
varying vec3 vColor;
varying float vBright, vRipple, vAlpha;

void main(){
  vec4 tex = texture2D(uDotTex, gl_PointCoord);
  if (tex.a < 0.01) discard;
  float soft = tex.a * tex.a;
  vec3 col = clamp(vColor * (0.55 + vBright * 0.62), vec3(0.0), vec3(1.8));
  float pulse = 1.0 + vRipple * 0.65;
  float lum = dot(vColor, vec3(0.299, 0.587, 0.114));
  float keepBlack = 1.0 - smoothstep(0.025, 0.115, lum);
  gl_FragColor = vec4(col, soft * uAlpha * uBloomStrength * pulse * 0.55 * vAlpha * (1.0 - keepBlack * 0.92));
}
`;

// 背景星河（原版的 backgroundStarRiver），单独一个场景、固定机位
export const starRiverVertexShader = /* glsl */ `
attribute float aSeed, aLane, aDepthSeed;
uniform float uTime, uBass, uTreble, uBeat, uEnergy, uPixel, uAlpha;
uniform vec3 uTintColor;
varying vec3 vColor;
varying float vAlpha, vTwinkle;

float hash11(float p){ return fract(sin(p * 127.1) * 43758.5453123); }

void main(){
  float band = floor(aLane * 6.0);
  float local = fract(aLane * 6.0);
  float bandN = (band + 0.5) / 6.0;
  float seed = aSeed + band * 19.17;
  float flow = fract(hash11(seed * 2.13) + uTime * (0.0022 + bandN * 0.0028 + hash11(seed * 5.1) * 0.0034));
  float arc = (flow - 0.5) * 6.2831853 * (0.68 + bandN * 0.46) + bandN * 2.4 + hash11(seed) * 6.2831853;
  float wave = sin(arc * (1.18 + bandN * 0.28) + uTime * (0.014 + bandN * 0.012) + seed * 0.07);
  float radius = 7.2 + bandN * 15.8 + hash11(seed * 3.7) * 6.2 + local * 1.8;
  vec3 pos;
  pos.x = cos(arc * 0.76 + bandN * 0.84) * radius + (flow - 0.5) * (18.0 + bandN * 14.0);
  pos.y = (bandN - 0.5) * 13.2 + wave * (1.5 + bandN * 1.4) + (local - 0.5) * 1.2;
  pos.z = mix(-31.0, -4.8, aDepthSeed) + wave * 1.2 + sin(uTime * (0.018 + hash11(seed) * 0.032) + seed) * 1.0;

  float twinkle = pow(0.5 + 0.5 * sin(uTime * (0.22 + hash11(seed * 4.0) * 0.44) + seed * 9.0), 5.0);
  float ridge = exp(-pow((local - (0.42 + hash11(seed * 6.0) * 0.16)) / (0.22 + hash11(seed * 7.0) * 0.10), 2.0));
  float dust = smoothstep(0.20, 0.98, hash11(seed * 8.0 + band));
  vec3 cool = mix(vec3(0.34, 0.76, 1.0), vec3(0.60, 0.44, 1.0), bandN);
  vec3 warm = vec3(1.0, 0.78, 0.58);
  vec3 tint = max(uTintColor, vec3(0.08));
  vColor = mix(cool, warm, ridge * 0.35 + uBass * 0.06);
  vColor = mix(vColor, tint, 0.22);
  vTwinkle = twinkle;
  vAlpha = uAlpha * dust * (0.10 + ridge * 0.52 + twinkle * 0.32 + uBeat * 0.05) * (0.88 + uEnergy * 0.18);

  vec4 mv = modelViewMatrix * vec4(pos, 1.0);
  float depthSize = 30.0 / max(0.65, -mv.z);
  float size = 1.10 + ridge * 2.40 + twinkle * 2.80 + uTreble * 0.80 + uBeat * 0.50;
  gl_PointSize = clamp(size * depthSize, 0.75, 5.60) * uPixel * 0.8;
  gl_Position = projectionMatrix * mv;
}
`;

export const starRiverFragmentShader = /* glsl */ `
uniform sampler2D uDotTex;
varying vec3 vColor;
varying float vAlpha, vTwinkle;

void main(){
  vec4 tex = texture2D(uDotTex, gl_PointCoord);
  if (tex.a < 0.02) discard;
  vec3 col = clamp(vColor * (0.66 + vTwinkle * 0.72), vec3(0.0), vec3(1.45));
  gl_FragColor = vec4(col, tex.a * vAlpha);
}
`;
