shader_type canvas_item;

// 从屏幕采样的纹理（Godot 4 官方写法）
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest_mipmap;

// 模糊强度，用 mipmap 等级来做简易模糊
// 0.0 = 不模糊；大概 0.0 ~ 3.0 之间比较实用
uniform float blur_amount : hint_range(0.0, 1.0) = 0.0;

// 右侧“柔和过渡带”的宽度（占这个 ColorRect 宽度的比例）
uniform float edge_softness : hint_range(0.0, 0.5) = 0.15;

void fragment() {
    // 在当前 ColorRect 内，左边 UV.x = 0，右边 UV.x = 1
    float x = UV.x;

    // edge = 1 时全强度，edge = 0 时完全不模糊
    // 在 [1 - edge_softness, 1] 区间里，从 1 平滑衰减到 0
    float edge = 1.0 - smoothstep(1.0 - edge_softness, 1.0, x);

    float lod = blur_amount * edge;

    if (lod <= 0.001) {
        // 不模糊，直接画原始屏幕
        COLOR = texture(screen_texture, SCREEN_UV);
    } else {
        // 用更高的 mipmap 等级，天然就是模糊版
        COLOR = textureLod(screen_texture, SCREEN_UV, lod);
    }
}
