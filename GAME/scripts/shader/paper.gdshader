shader_type canvas_item;

// ===============
// 可选输入贴图
// ===============
uniform sampler2D paper_tex : source_color;
uniform bool use_paper_tex = false;

uniform sampler2D noise_tex : source_color;   // 建议灰度噪声（grain / FBM）
uniform sampler2D crease_tex : source_color;  // 折痕/裂纹灰度
uniform bool use_crease = false;

// ===============
// 纸张与底色
// ===============
uniform vec4  paper_tint         = vec4(0.92, 0.86, 0.73, 1.0); // 牛皮纸基色
uniform vec2  paper_uv_scale     = vec2(2.0, 2.0);              // 平铺倍率
uniform float grain_strength     = 0.15;                        // 纸面颗粒强度
uniform float stain_amount       = 0.12;                        // 污渍强度
uniform float vignette_strength  = 0.20;                        // 暗角强度（0-1）

// ===============
// 边缘做旧（方案4）
// ===============
uniform float edge_wear        = 0.55;  // 越大越磨
uniform float corner_wear      = 0.45;  // 四角加成
uniform float edge_cut         = 0.35;  // 咬边裁切，透明“毛边”
uniform float crease_intensity = 0.35;  // 折痕/裂纹强度（需 use_crease）
uniform float paper_warp       = 0.002; // 纸面微翘曲（UV 扰动）

// ===============
// 印刷/油墨（方案5）
// ===============
uniform float ink_bleed_px       = 1.5;   // 渗色像素半径（0 关闭）
uniform float halftone_amount    = 0.35;  // 网点强度
uniform float halftone_scale     = 260.0; // 网点密度（越大越密）
uniform float halftone_angle_deg = 45.0;  // 网屏角度（典型45°）
uniform float dot_gain           = 0.25;  // 增墨（变暗/铺大）
uniform float desaturate         = 0.10;  // 去饱和
uniform float contrast_fade      = -0.08; // 对比度回退（-0.5~0.5）

// ===============
// 实例随机（避免同花样）
// ===============
uniform vec2 instance_seed = vec2(0.37, 0.83);

// ---------- 工具函数（无 mat2 版本） ----------
vec2 rotate2d(vec2 p, float a){
    float s = sin(a), c = cos(a);
    // [ c -s; s c ] * p
    return vec2(c * p.x - s * p.y,
                s * p.x + c * p.y);
}

// 计算任意采样器的 texel 尺寸（UV 下的一像素）
vec2 texel_size(sampler2D tex){
    // textureSize(tex, 0) 返回像素分辨率 (width, height)
    return 1.0 / vec2(textureSize(tex, 0));
}

// 9-tap 邻域采样（墨水渗色用）
vec4 bleed_sample(sampler2D tex, vec2 uv){
    vec2 t = texel_size(tex); // ← 替代 TEXTURE_PIXEL_SIZE
    vec4 c = texture(tex, uv);
    c += texture(tex, uv + vec2( t.x, 0.0));
    c += texture(tex, uv + vec2(-t.x, 0.0));
    c += texture(tex, uv + vec2(0.0,  t.y));
    c += texture(tex, uv + vec2(0.0, -t.y));
    c += texture(tex, uv + vec2( t.x,  t.y));
    c += texture(tex, uv + vec2(-t.x,  t.y));
    c += texture(tex, uv + vec2( t.x, -t.y));
    c += texture(tex, uv + vec2(-t.x, -t.y));
    return c / 9.0;
}


float luma(vec3 c){ return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 contrast(vec3 c, float k){
    return (c - 0.5) * (1.0 + k) + 0.5;
}

// 生成边缘磨损/咬边掩码（0~1）
float edge_mask(vec2 uv, vec2 seed){
    float d_edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float d0 = length(uv - vec2(0.0,0.0));
    float d1 = length(uv - vec2(1.0,0.0));
    float d2 = length(uv - vec2(0.0,1.0));
    float d3 = length(uv - vec2(1.0,1.0));
    float corner = min(min(d0,d1), min(d2,d3));

    // 噪声扰动
    vec2 n_uv = uv * 6.0 + seed * 13.0;
    float n = texture(noise_tex, n_uv).r;

    float wear_t = mix(0.18, 0.45, 1.0 - edge_wear);
    wear_t -= corner_wear * (0.25 - corner);

    float m = smoothstep(wear_t - 0.05, wear_t + 0.05, d_edge + (n - 0.5) * 0.06);
    return clamp(m, 0.0, 1.0);
}

// 单通道网点（用亮度域叠加）
float halftone_val(vec2 uv, float amount, float scale, float angle_deg){
    if (amount <= 0.0) return 0.0;
    float a = radians(angle_deg);
    vec2 p = rotate2d((uv - 0.5) * scale, a);
    float s = sin(p.x) * sin(p.y);
    return 0.5 + 0.5 * s; // [-1,1] → [0,1]
}

void fragment(){
    vec2 uv = UV;

    // 纸面轻翘曲（UV 扰动）
    if (paper_warp > 0.0){
        float wn = texture(noise_tex, uv * 2.0 + instance_seed).r;
        uv += (wn - 0.5) * paper_warp;
    }

    // 前景：TextureRect 的 Texture（你的卡面 PNG）
    vec4 fg = texture(TEXTURE, uv);

    // —— 印刷处理 —— //
    // 1) 油墨渗色
    if (ink_bleed_px > 0.0){
        vec4 blur = bleed_sample(TEXTURE, UV);
        float a = fg.a;
        fg.rgb = mix(fg.rgb, blur.rgb, clamp(a * ink_bleed_px * 0.25, 0.0, 1.0));
    }

    // 2) 去饱和
    float Y = luma(fg.rgb);
    fg.rgb = mix(fg.rgb, vec3(Y), clamp(desaturate, 0.0, 1.0));

    // 3) Dot Gain 增墨（平方近似变暗）
    vec3 darkened = fg.rgb * fg.rgb;
    fg.rgb = mix(fg.rgb, darkened, clamp(dot_gain, 0.0, 1.0));

    // 4) 网点/网屏（作用在亮度域）
    if (halftone_amount > 0.0){
        float ht = halftone_val(UV, halftone_amount, halftone_scale, halftone_angle_deg);
        float y = luma(fg.rgb);
        y = mix(y, ht, clamp(halftone_amount, 0.0, 1.0));

        // 以原色相近似保留色彩：用亮度替换
        float eps = 1e-5;
        vec3 nrm = fg.rgb / max(Y, eps);
        fg.rgb = clamp(nrm * y, 0.0, 1.0);
    }

    // 5) 对比度回退
    fg.rgb = contrast(fg.rgb, contrast_fade);

    // —— 纸底层 —— //
    vec4 paper_col = vec4(paper_tint.rgb, 1.0);
    if (use_paper_tex){
        vec3 base = texture(paper_tex, UV * paper_uv_scale + instance_seed).rgb;
        paper_col.rgb *= base;
    }
    // 纸粒与污渍（基于 noise_tex）
    float g = texture(noise_tex, UV * paper_uv_scale * 2.5 + instance_seed * 7.0).r;
    paper_col.rgb = mix(paper_col.rgb, paper_col.rgb * (0.85 + g * 0.3), grain_strength);

    float s = texture(noise_tex, (UV + instance_seed) * 1.3).r;
    paper_col.rgb = mix(paper_col.rgb, paper_col.rgb * (0.75 + s * 0.5), stain_amount);

    // 折痕/裂纹（乘暗）
    if (use_crease){
        vec3 crease = texture(crease_tex, UV * (paper_uv_scale * 0.8 + 0.2)).rgb;
        paper_col.rgb *= mix(vec3(1.0), crease, crease_intensity);
    }

    // —— 暗角 —— //
    if (vignette_strength > 0.0){
        vec2 p = (UV - 0.5) / vec2(0.5, 0.5);
        float v = clamp(1.0 - dot(p, p), 0.0, 1.0);
        paper_col.rgb *= mix(1.0, smoothstep(0.0, 1.0, v), 1.0 - vignette_strength);
    }

    // —— 边缘做旧与咬边 —— //
    float em = edge_mask(UV, instance_seed);
    float alpha_cut = smoothstep(edge_cut, edge_cut + 0.15, em); // 毛边透明

    // —— 纸+油墨合成 —— //
    // 视作“墨”印到纸上：paper * (1 - A) + fg * A
    vec3 ink_on_paper = mix(paper_col.rgb, fg.rgb, fg.a);

    COLOR.rgb = ink_on_paper;
    COLOR.a   = alpha_cut; // 若不想裁切边缘：可改为 COLOR.a = fg.a; 或 1.0
}
