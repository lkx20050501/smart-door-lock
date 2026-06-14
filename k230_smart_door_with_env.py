# k230_smart_door_with_env.py - 智能门禁系统 (集成环境控制)
# 基于 k230_smart_door_fixed.py V17 + 温湿度/光敏/LED补光/散热风扇
# LED和风扇默认自动模式

import time, os, gc, math
import network
import socket
import ujson
import _thread

from media.sensor import *
from media.display import *
from media.media import *

from libs.PipeLine import PipeLine, ScopedTiming
from libs.AIBase import AIBase
from libs.AI2D import Ai2d
import nncase_runtime as nn
import ulab.numpy as np
import aidemo
import image

# 环境控制模块 - 内嵌版

from machine import PWM
import machine as _machine

# ==================== 环境控制引脚配置 ====================
ENV_LED_PIN = 42         # 白光LED (PWM)
ENV_FAN_PIN = 43         # 散热风扇 (PWM, 接驱动模块)

# ==================== 自动控制阈值 ====================
ENV_FAN_TEMP_START = 60.0      # 风扇开始转动温度
ENV_FAN_TEMP_MAX = 80.0        # 风扇满速温度
ENV_FAN_TEMP_STOP = 50.0       # 风扇停止温度(回差)
ENV_FAN_MIN_DUTY = 30          # 风扇最低启动占空比
ENV_LED_AUTO_BRIGHTNESS = 80   # 自动补光亮度百分比
ENV_CAM_DARK_THRESHOLD = 100   # 摄像头帧平均亮度 < 此值视为暗



# ==================== LED 白光补光 ====================
class LEDController:
    def __init__(self, pin_num):
        self.pwm = PWM(pin_num, freq=1000, duty=0)
        self._duty = 0
        self.mode = 'auto'
        self._manual_duty = 80

    def set_duty(self, percent):
        percent = max(0, min(100, int(percent)))
        self._duty = percent
        self.pwm.duty(percent)

    @property
    def duty(self):
        return self._duty

    def on(self):
        self.mode = 'manual'
        self.set_duty(self._manual_duty)

    def off(self):
        self.mode = 'manual'
        self.set_duty(0)

    def set_manual(self, value):
        self.mode = 'manual'
        self._manual_duty = max(0, min(100, int(value)))
        self.set_duty(self._manual_duty)

    def auto(self):
        self.mode = 'auto'

# ==================== 散热风扇 ====================
class FanController:
    def __init__(self, pin_num):
        self.pwm = PWM(pin_num, freq=1000, duty=0)
        self._duty = 0
        self.mode = 'auto'
        self._manual_duty = 50

    def set_duty(self, percent):
        percent = max(0, min(100, int(percent)))
        self._duty = percent
        self.pwm.duty(percent)

    @property
    def duty(self):
        return self._duty

    def on(self):
        self.mode = 'manual'
        self.set_duty(self._manual_duty)

    def off(self):
        self.mode = 'manual'
        self.set_duty(0)

    def set_manual(self, value):
        self.mode = 'manual'
        self._manual_duty = max(0, min(100, int(value)))
        self.set_duty(self._manual_duty)

    def auto(self):
        self.mode = 'auto'

    def auto_control(self, chip_temp):
        if chip_temp >= ENV_FAN_TEMP_START:
            ratio = (chip_temp - ENV_FAN_TEMP_START) / (ENV_FAN_TEMP_MAX - ENV_FAN_TEMP_START)
            ratio = max(0.0, min(1.0, ratio))
            duty = ENV_FAN_MIN_DUTY + int((100 - ENV_FAN_MIN_DUTY) * ratio)
        elif chip_temp < ENV_FAN_TEMP_STOP:
            duty = 0
        else:
            return
        self.set_duty(duty)

# ==================== 环境总控 ====================
class EnvMonitor:
    def __init__(self):
        self.led = LEDController(ENV_LED_PIN)
        self.fan = FanController(ENV_FAN_PIN)
        self.chip_temp = 0.0
        self.last_tick_ms = 0
        self._busy = False
        self._auto_led_counter = 0

    def read_chip_temp(self):
        try:
            self.chip_temp = _machine.temperature()
        except:
            pass

    def auto_led(self, img):
        """根据摄像头帧亮度自动控制补光LED"""
        if self.led.mode != 'auto':
            return
        self._auto_led_counter += 1
        if self._auto_led_counter % 15 != 0:
            return
        try:
            avg = float(np.mean(img))
            target = ENV_LED_AUTO_BRIGHTNESS if avg < ENV_CAM_DARK_THRESHOLD else 0
            if self.led._duty != target:
                self.led.set_duty(target)
                print(f"[补光] 切换 LED={target}% (avg={avg:.1f})")
        except BaseException as e:
            print(f"[补光] 异常: {e}")

    def tick(self):
        os.exitpoint()

        now = time.ticks_ms()
        if self.last_tick_ms > 0:
            if time.ticks_diff(now, self.last_tick_ms) < 60000:
                return
        self.last_tick_ms = now

        if self._busy:
            return
        self._busy = True
        try:
            self.read_chip_temp()

            if self.fan.mode == 'auto':
                try:
                    self.fan.auto_control(self.chip_temp)
                except:
                    pass
        finally:
            self._busy = False

    def status(self):
        return {
            'chip_temp': round(self.chip_temp, 1),
            'light': 0,
            'led_duty': self.led.duty,
            'led_mode': self.led.mode,
            'fan_duty': self.fan.duty,
            'fan_mode': self.fan.mode,
        }

# 预生成的HTML页面 (仅生成一次, 避免每次请求消耗内存)
INDEX_HTML = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>K230智能门禁</title>
<style>
body{font-family:Arial;text-align:center;padding:10px;background:#f0f0f0;margin:0}
.card{background:white;padding:15px;border-radius:10px;max-width:420px;margin:8px auto;box-shadow:0 2px 8px rgba(0,0,0,0.1)}
h1{color:#333;font-size:18px;margin:0 0 8px 0}
hr{border:none;border-top:1px solid #eee;margin:10px 0}
.btn{padding:10px 20px;margin:3px;border:none;border-radius:5px;cursor:pointer;font-size:13px;color:white}
.bg{background:#28a745}.br{background:#dc3545}.bb{background:#007bff}.bgray{background:#6c757d}
.bsm{padding:6px 12px;font-size:12px}.bactive{outline:3px solid #ffc107}
.row{display:flex;align-items:center;justify-content:space-between;margin:5px 0}
.lb{font-size:13px;color:#666;min-width:60px;text-align:left}
.val{font-size:15px;font-weight:bold;color:#333}
.sl{width:120px;accent-color:#007bff}
.eg{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin:8px 0}
.ei{background:#f8f9fa;padding:8px;border-radius:6px;text-align:center}
.ei .lb{font-size:11px;color:#888;display:block}
.ei .val{font-size:18px;margin:2px 0}
#fi{max-width:100%;margin-top:8px;border-radius:8px}
</style></head><body>
<div class="card">
<h1>K230 智能门禁 V18</h1>
<p id="st" style="font-size:14px;margin:4px 0">加载中...</p>
<button class="btn bg" onclick="c('open')">开门</button>
<button class="btn br" onclick="c('close')">关门</button>
<button class="btn bb" onclick="c('register')">注册人脸</button>
<button class="btn bgray" onclick="if(confirm('清空所有人脸?'))c('clear_faces')">清空</button>
</div>
<div class="card">
<h1>环境监控</h1>
<div class="eg">
<div class="ei"><span class="lb">温度</span><span class="val" id="vt">--</span></div>
<div class="ei"><span class="lb">湿度</span><span class="val" id="vh">--</span></div>
<div class="ei"><span class="lb">芯片温度</span><span class="val" id="vc">--</span></div>
<div class="ei"><span class="lb">光照</span><span class="val" id="vl">--</span></div>
</div>
<hr>
<div class="row">
<span class="lb">LED 补光</span>
<button class="btn bsm" id="bla" onclick="ec('led/auto')">自动</button>
<button class="btn bsm bg" onclick="ec('led/on')">开</button>
<button class="btn bsm br" onclick="ec('led/off')">关</button>
<input type="range" class="sl" id="ls" min="0" max="100" value="80" onchange="ec('led/set?value='+this.value)">
<span id="vlp" style="font-size:12px;min-width:36px">0%</span>
</div>
<div class="row">
<span class="lb">散热风扇</span>
<button class="btn bsm" id="bfa" onclick="ec('fan/auto')">自动</button>
<button class="btn bsm bg" onclick="ec('fan/on')">开</button>
<button class="btn bsm br" onclick="ec('fan/off')">关</button>
<input type="range" class="sl" id="fs" min="0" max="100" value="50" onchange="ec('fan/set?value='+this.value)">
<span id="vfp" style="font-size:12px;min-width:36px">0%</span>
</div>
</div>
<div class="card">
<img id="fi" src="" style="display:none">
</div>
<script>
function c(u){fetch('/'+u).then(r=>r.json()).then(d=>{if(d.message)alert(d.message);A()}).catch(e=>alert('操作失败'))}
function ec(u){fetch('/'+u).then(r=>r.json()).then(d=>ue())}
function ue(){fetch('/env_status').then(r=>r.json()).then(d=>{
document.getElementById('vt').textContent=d.aht_error?'错误':((d.temp||'--')+'°C');
document.getElementById('vh').textContent=d.aht_error?'错误':((d.humidity||'--')+'%');
document.getElementById('vc').textContent=(d.chip_temp||'--')+'C';
document.getElementById('vl').textContent=d.light==1?'暗':'亮';
document.getElementById('vlp').textContent=(d.led_duty||0)+'%';
document.getElementById('vfp').textContent=(d.fan_duty||0)+'%';
document.getElementById('ls').value=d.led_duty||0;
document.getElementById('fs').value=d.fan_duty||0;
var la=document.getElementById('bla'),fa=document.getElementById('bfa');
la.className=d.led_mode=='auto'?'btn bsm bactive':'btn bsm';
la.style.background=d.led_mode=='auto'?'#ffc107':'';
la.style.color=d.led_mode=='auto'?'#333':'white';
fa.className=d.fan_mode=='auto'?'btn bsm bactive':'btn bsm';
fa.style.background=d.fan_mode=='auto'?'#ffc107':'';
fa.style.color=d.fan_mode=='auto'?'#333':'white';
document.getElementById('ls').disabled=d.led_mode=='auto';
document.getElementById('fs').disabled=d.fan_mode=='auto';
}).catch(e=>{})}
function uf(){fetch('/face_recog').then(r=>r.json()).then(d=>{
var s=d.result==1?'已识别:'+d.name:d.result==2?'?未知人脸':'等待中';
document.getElementById('st').innerHTML='状态:'+s+' | 人脸:'+d.face_count;
}).catch(e=>{});
var img=document.getElementById('fi');
fetch('/face_image').then(r=>{
if(r.headers.get('content-type')&&r.headers.get('content-type').includes('image')){
r.blob().then(b=>{img.src=URL.createObjectURL(b);img.style.display='block'});
}else{img.style.display='none'}
}).catch(e=>{})}
function A(){ue();uf()}
A();setInterval(ue,3000);setInterval(uf,2000);
</script></body></html>"""

print("=" * 50)
print("  K230 智能门禁系统 V18 - 集成环境控制")
print("  LED补光 + 温湿度 + 芯片散热")
print("=" * 50)

# ==================== 配置 ====================
WIDTH = 640
HEIGHT = 480

WIFI_SSID = "lkx"
WIFI_PASSWORD = "123456789"

HTTP_PORT = 8080

FACE_COSINE_THRESHOLD = 0.55
FACE_THRESHOLD = FACE_COSINE_THRESHOLD

FACE_DET_KMODEL = "/sdcard/kmodel/face_detection_320.kmodel"
FACE_REG_KMODEL = "/sdcard/kmodel/face_recognition.kmodel"
ANCHORS_PATH = "/sdcard/utils/prior_data_320.bin"
DATABASE_DIR = "/data/face_database/"

TEMP_IMAGE_PATH = "/sdcard/temp_face.jpg"

KNOWN_FACE_IMAGE_INTERVAL = 5 * 60 * 1000
UNKNOWN_FACE_IMAGE_INTERVAL = 60 * 1000

# ==================== 全局变量 ====================
device_ip = "0.0.0.0"
door_status = 0
running = True

lock = _thread.allocate_lock()

register_request = False
register_result = {"status": "idle", "message": ""}

face_recog_result = 0
face_recog_name = ""
face_recog_score = 0.0
face_count = 0
face_list = []

detected_face_info = None
has_new_face_image = False

save_in_progress = False
face_last_save_time = {}

# 环境监控
env_monitor = None

# ==================== 人脸检测类 ====================
class FaceDetApp(AIBase):
    def __init__(self, kmodel_path, model_input_size, anchors, confidence_threshold=0.5,
                 nms_threshold=0.3, rgb888p_size=[640,480], display_size=[640,480], debug_mode=0):
        super().__init__(kmodel_path, model_input_size, rgb888p_size, debug_mode)
        self.kmodel_path = kmodel_path
        self.model_input_size = model_input_size
        self.confidence_threshold = confidence_threshold
        self.nms_threshold = nms_threshold
        self.anchors = anchors
        self.rgb888p_size = [ALIGN_UP(rgb888p_size[0],16), rgb888p_size[1]]
        self.display_size = [ALIGN_UP(display_size[0],16), display_size[1]]
        self.debug_mode = debug_mode
        self.ai2d = Ai2d(debug_mode)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT, np.uint8, np.uint8)

    def config_preprocess(self, input_image_size=None):
        with ScopedTiming("set preprocess config", self.debug_mode > 0):
            ai2d_input_size = input_image_size if input_image_size else self.rgb888p_size
            self.ai2d.pad(self.get_pad_param(), 0, [104,117,123])
            self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
            self.ai2d.build([1,3,ai2d_input_size[1],ai2d_input_size[0]],
                          [1,3,self.model_input_size[1],self.model_input_size[0]])

    def postprocess(self, results):
        with ScopedTiming("postprocess", self.debug_mode > 0):
            res = aidemo.face_det_post_process(self.confidence_threshold, self.nms_threshold,
                                              self.model_input_size[0], self.anchors,
                                              self.rgb888p_size, results)
            if len(res) == 0:
                return [], []
            return res[0], res[1]

    def get_pad_param(self):
        dst_w, dst_h = self.model_input_size[0], self.model_input_size[1]
        ratio = min(dst_w / self.rgb888p_size[0], dst_h / self.rgb888p_size[1])
        new_w, new_h = int(ratio * self.rgb888p_size[0]), int(ratio * self.rgb888p_size[1])
        dw, dh = (dst_w - new_w) / 2, (dst_h - new_h) / 2
        return [0, 0, 0, 0, int(round(0)), int(round(dh * 2 + 0.1)), int(round(0)), int(round(dw * 2 - 0.1))]

# ==================== 人脸特征类 ====================
class FaceRegApp(AIBase):
    def __init__(self, kmodel_path, model_input_size, rgb888p_size=[640,480], display_size=[640,480], debug_mode=0):
        super().__init__(kmodel_path, model_input_size, rgb888p_size, debug_mode)
        self.kmodel_path = kmodel_path
        self.model_input_size = model_input_size
        self.rgb888p_size = [ALIGN_UP(rgb888p_size[0],16), rgb888p_size[1]]
        self.display_size = [ALIGN_UP(display_size[0],16), display_size[1]]
        self.debug_mode = debug_mode
        self.umeyama_args_112 = [38.2946, 51.6963, 73.5318, 51.5014, 56.0252, 71.7366, 41.5493, 92.3655, 70.7299, 92.2041]
        self.ai2d = Ai2d(debug_mode)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT, np.uint8, np.uint8)

    def config_preprocess(self, landm, input_image_size=None):
        with ScopedTiming("set preprocess config", self.debug_mode > 0):
            ai2d_input_size = input_image_size if input_image_size else self.rgb888p_size
            affine_matrix = self.get_affine_matrix(landm)
            self.ai2d.affine(nn.interp_method.cv2_bilinear, 0, 0, 127, 1, affine_matrix)
            self.ai2d.build([1,3,ai2d_input_size[1],ai2d_input_size[0]],
                          [1,3,self.model_input_size[1],self.model_input_size[0]])

    def postprocess(self, results):
        return results[0][0]

    def get_affine_matrix(self, landm):
        dst = self.umeyama_args_112
        src = landm

        src_pts = [(src[0], src[1]), (src[2], src[3]), (src[4], src[5]), (src[6], src[7]), (src[8], src[9])]
        dst_pts = [(dst[0], dst[1]), (dst[2], dst[3]), (dst[4], dst[5]), (dst[6], dst[7]), (dst[8], dst[9])]

        src_mean_x = sum(p[0] for p in src_pts) / 5
        src_mean_y = sum(p[1] for p in src_pts) / 5
        dst_mean_x = sum(p[0] for p in dst_pts) / 5
        dst_mean_y = sum(p[1] for p in dst_pts) / 5

        src_demean = [(p[0] - src_mean_x, p[1] - src_mean_y) for p in src_pts]
        dst_demean = [(p[0] - dst_mean_x, p[1] - dst_mean_y) for p in dst_pts]

        a00 = sum(d[0] * s[0] for d, s in zip(dst_demean, src_demean))
        a01 = sum(d[0] * s[1] for d, s in zip(dst_demean, src_demean))
        a10 = sum(d[1] * s[0] for d, s in zip(dst_demean, src_demean))
        a11 = sum(d[1] * s[1] for d, s in zip(dst_demean, src_demean))

        src_var = sum(s[0]**2 + s[1]**2 for s in src_demean)

        if src_var < 1e-10:
            return [1.0, 0.0, dst_mean_x - src_mean_x, 0.0, 1.0, dst_mean_y - src_mean_y]

        ata00 = a00*a00 + a10*a10
        ata01 = a00*a01 + a10*a11
        ata11 = a01*a01 + a11*a11

        trace = ata00 + ata11
        det = ata00 * ata11 - ata01 * ata01

        discriminant = trace * trace - 4 * det
        if discriminant < 0:
            discriminant = 0
        sqrt_disc = math.sqrt(discriminant)

        lambda1 = (trace + sqrt_disc) / 2
        lambda2 = (trace - sqrt_disc) / 2

        s1 = math.sqrt(max(0, lambda1))
        s2 = math.sqrt(max(0, lambda2))

        det_a = a00 * a11 - a01 * a10
        scale = (s1 + s2) / src_var if src_var > 1e-10 else 1.0

        num = a10 - a01
        den = a00 + a11

        if abs(den) < 1e-10 and abs(num) < 1e-10:
            theta = 0.0
        else:
            theta = math.atan2(num, den)

        cos_t = math.cos(theta)
        sin_t = math.sin(theta)

        r00 = scale * cos_t
        r01 = scale * (-sin_t)
        r10 = scale * sin_t
        r11 = scale * cos_t

        t0 = dst_mean_x - r00 * src_mean_x - r01 * src_mean_y
        t1 = dst_mean_y - r10 * src_mean_x - r11 * src_mean_y

        return [r00, r01, t0, r10, r11, t1]

# ==================== 人脸数据库管理 ====================
class FaceDatabase:
    def __init__(self, database_dir, max_faces=10, threshold=FACE_THRESHOLD):
        self.database_dir = database_dir
        self.max_faces = max_faces
        self.threshold = threshold
        self.db_data = []
        self.db_name = []
        self.db_features = {}
        self._ensure_dir(database_dir)
        self.load()

    def _ensure_dir(self, directory):
        directory = directory.rstrip('/')
        try:
            os.stat(directory)
        except:
            parts = directory.split('/')
            path = ''
            for part in parts:
                if part:
                    path += '/' + part
                    try:
                        os.stat(path)
                    except:
                        try:
                            os.mkdir(path)
                        except:
                            pass

    def load(self):
        self.db_data = []
        self.db_name = []
        self.db_features = {}

        try:
            files = os.listdir(self.database_dir)
        except:
            print("[人脸库] 目录为空")
            return

        name_files = {}

        for f in files:
            if not f.endswith('.bin'):
                continue
            base_name = f.replace('.bin', '')
            parts = base_name.rsplit('_', 1)
            if len(parts) == 2 and parts[1].isdigit() and int(parts[1]) > 0:
                main_name = parts[0]
            else:
                main_name = base_name

            if main_name not in name_files:
                name_files[main_name] = []
            name_files[main_name].append(f)

        for name in sorted(name_files.keys()):
            if len(self.db_data) >= self.max_faces:
                break
            features = []
            for f in name_files[name]:
                try:
                    with open(self.database_dir + f, 'rb') as file:
                        feat = np.frombuffer(file.read(), dtype=np.float)
                    feat_norm = float(np.linalg.norm(feat))
                    if feat_norm > 0.1:
                        features.append(feat / feat_norm)
                except Exception as e:
                    print(f"[人脸库] 加载失败: {f}, {e}")

            if features:
                avg_feat = features[0]
                for f in features[1:]:
                    avg_feat = avg_feat + f
                avg_feat = avg_feat / np.linalg.norm(avg_feat)
                self.db_data.append(avg_feat)
                self.db_name.append(name)
                self.db_features[name] = features
                print(f"[人脸库] 加载: {name} ({len(features)}张特征)")

        print(f"[人脸库] 共加载 {len(self.db_data)} 个人脸")

    def search(self, feature):
        if not self.db_data:
            return None, 0.0
        input_norm = float(np.linalg.norm(feature))
        if input_norm < 0.1:
            return None, 0.0
        feature_norm = feature / input_norm
        best_id, best_score = -1, -1.0

        for i, name in enumerate(self.db_name):
            max_sim = -1.0
            for db_feat in self.db_features[name]:
                cosine_sim = float(np.dot(feature_norm, db_feat))
                if cosine_sim > max_sim:
                    max_sim = cosine_sim
            status = "✓" if max_sim >= self.threshold else "✗"
            feat_count = len(self.db_features[name])
            print(f"[识别] {status} {name}({feat_count}张): {max_sim:.4f} (阈值:{self.threshold})")
            if max_sim > best_score:
                best_score = max_sim
                best_id = i

        if best_id >= 0 and best_score >= self.threshold:
            return self.db_name[best_id], best_score
        return None, best_score

    def add(self, feature, name=None):
        feat_norm = float(np.linalg.norm(feature))
        if feat_norm < 0.1:
            return False, "特征无效"
        feature_normalized = feature / feat_norm

        if not name:
            existing_nums = []
            for n in self.db_name:
                if n.startswith("Face_"):
                    try:
                        num = int(n.replace("Face_", ""))
                        existing_nums.append(num)
                    except:
                        pass
            next_num = max(existing_nums) + 1 if existing_nums else 1
            name = f"Face_{next_num}"

        if name in self.db_name:
            feat_count = len(self.db_features[name])
            filename = f"{name}_{feat_count}.bin"
        else:
            if len(self.db_data) >= self.max_faces:
                return False, "人脸库已满"
            filename = f"{name}.bin"

        try:
            with open(self.database_dir + filename, 'wb') as f:
                f.write(feature_normalized.tobytes())
        except Exception as e:
            return False, f"保存失败: {e}"

        if name in self.db_name:
            self.db_features[name].append(feature_normalized)
            avg_feat = self.db_features[name][0]
            for f in self.db_features[name][1:]:
                avg_feat = avg_feat + f
            avg_feat = avg_feat / np.linalg.norm(avg_feat)
            idx = self.db_name.index(name)
            self.db_data[idx] = avg_feat
            return True, f"添加成功: {name} (现有{len(self.db_features[name])}张)"
        else:
            self.db_data.append(feature_normalized)
            self.db_name.append(name)
            self.db_features[name] = [feature_normalized]
            return True, f"注册成功: {name}"

    def delete(self, name):
        if name not in self.db_name:
            return False
        try:
            for f in os.listdir(self.database_dir):
                if f.startswith(name) and f.endswith('.bin'):
                    os.remove(self.database_dir + f)
            idx = self.db_name.index(name)
            self.db_data.pop(idx)
            self.db_name.remove(name)
            del self.db_features[name]
            return True
        except:
            return False

    def clear(self):
        try:
            for f in os.listdir(self.database_dir):
                if f.endswith('.bin'):
                    os.remove(self.database_dir + f)
        except:
            pass
        self.db_data = []
        self.db_name = []
        self.db_features = {}

    @property
    def count(self):
        return len(self.db_data)

    @property
    def names(self):
        return self.db_name.copy()

# ==================== WiFi连接 ====================
def connect_wifi():
    global device_ip
    print("\n[WiFi] 连接网络...")
    print(f"[WiFi] SSID: {WIFI_SSID}")

    try:
        sta = network.WLAN(network.STA_IF)
        if not sta.active():
            sta.active(True)
        if sta.isconnected():
            sta.disconnect()
            time.sleep(1)
        sta.connect(WIFI_SSID, WIFI_PASSWORD)
        print("[WiFi] 等待连接", end="")
        timeout = 30
        while not sta.isconnected() and timeout > 0:
            print(".", end="")
            time.sleep(1)
            timeout -= 1
        print()
        if sta.isconnected():
            device_ip = sta.ifconfig()[0]
            print(f"[WiFi] 连接成功! IP: {device_ip}")
            return True
        else:
            print("[WiFi] 连接失败!")
            return False
    except Exception as e:
        print(f"[WiFi] 错误: {e}")
        return False

# WiFi重连检查 (激进策略: deactive→active→connect)
_wifi_check_counter = 0
def check_wifi_reconnect():
    global _wifi_check_counter, device_ip
    _wifi_check_counter = (_wifi_check_counter + 1) % 500  # 约每10秒检查一次
    if _wifi_check_counter != 0:
        return True
    try:
        sta = network.WLAN(network.STA_IF)
        if sta.isconnected():
            return True
        print("[WiFi] 连接丢失, 尝试激进重连...")
        sta.active(False)
        time.sleep_ms(500)
        sta.active(True)
        time.sleep_ms(500)
        sta.connect(WIFI_SSID, WIFI_PASSWORD)
        for _ in range(15):
            time.sleep(1)
            if sta.isconnected():
                device_ip = sta.ifconfig()[0]
                print(f"[WiFi] 重连成功! IP: {device_ip}")
                return True
        print("[WiFi] 重连失败!")
        return False
    except Exception as e:
        print(f"[WiFi] 重连异常: {e}")
        return False

# ==================== HTTP服务器 ====================
http_server = None

def init_http():
    global http_server
    print(f"\n[HTTP] 端口: {HTTP_PORT}")
    try:
        http_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        http_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        http_server.bind(('0.0.0.0', HTTP_PORT))
        http_server.listen(5)
        print("[HTTP] 成功!")
        return True
    except Exception as e:
        print(f"[HTTP] 错误: {e}")
        return False

def send_response(client, body, content_type="application/json", status="200 OK"):
    try:
        body_bytes = body.encode('utf-8') if isinstance(body, str) else body
        header = f"HTTP/1.1 {status}\r\n"
        header += f"Content-Type: {content_type}\r\n"
        header += f"Content-Length: {len(body_bytes)}\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: *\r\n"
        header += "Access-Control-Expose-Headers: X-Face-Result, X-Face-Name, X-Face-Score\r\n"
        header += "Connection: close\r\n\r\n"
        client.sendall(header.encode('utf-8'))
        client.sendall(body_bytes)
    except Exception as e:
        print(f"[发送错误] {e}")

def send_file_image(client, filepath, info):
    try:
        with open(filepath, 'rb') as f:
            jpeg_data = f.read()
        if len(jpeg_data) < 100:
            return False

        header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: image/jpeg\r\n"
        header += f"Content-Length: {len(jpeg_data)}\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Expose-Headers: X-Face-Result, X-Face-Name, X-Face-Score\r\n"
        header += f"X-Face-Result: {info['result']}\r\n"
        header += f"X-Face-Name: {info['name']}\r\n"
        header += f"X-Face-Score: {info['score']:.2f}\r\n"
        header += "Connection: close\r\n\r\n"

        client.sendall(header.encode('utf-8'))
        chunk_size = 2048
        sent = 0
        while sent < len(jpeg_data):
            end = min(sent + chunk_size, len(jpeg_data))
            client.sendall(jpeg_data[sent:end])
            sent = end
        return True
    except Exception as e:
        print(f"[图片发送错误] {e}")
        return False

def handle_request(client, addr):
    global door_status, register_request, register_result
    global face_recog_result, face_recog_name, face_recog_score, face_count, face_list, face_db
    global detected_face_info, has_new_face_image
    global env_monitor

    try:
        client.settimeout(10.0)
        client.setblocking(True)

        data = b''
        while True:
            try:
                chunk = client.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b'\r\n\r\n' in data:
                    header_end = data.find(b'\r\n\r\n')
                    headers = data[:header_end].decode('utf-8', 'ignore')
                    content_length = 0
                    for line in headers.split('\r\n'):
                        if line.lower().startswith('content-length:'):
                            content_length = int(line.split(':')[1].strip())
                            break
                    body_received = len(data) - header_end - 4
                    if body_received >= content_length:
                        break
                    if content_length == 0:
                        break
            except:
                break

        if not data:
            return

        header_end = data.find(b'\r\n\r\n')
        if header_end < 0:
            return

        header_data = data[:header_end].decode('utf-8', 'ignore')
        lines = header_data.split('\r\n')
        first_line = lines[0]
        parts = first_line.split(' ')
        method = parts[0] if len(parts) >= 1 else 'GET'
        path = parts[1] if len(parts) >= 2 else '/'

        if method == 'OPTIONS':
            send_response(client, '', 'text/plain', '204 No Content')
            return

        # ==================== 环境控制API ====================
        if path == '/env_status':
            status = env_monitor.status() if env_monitor else {}
            send_response(client, ujson.dumps(status))

        elif path.startswith('/led/'):
            if env_monitor:
                sub = path.split('/led/')[1]
                if sub == 'on':
                    env_monitor.led.on()
                elif sub == 'off':
                    env_monitor.led.off()
                elif sub == 'auto':
                    env_monitor.led.auto()
                elif sub.startswith('set'):
                    q = path.find('value=')
                    if q > 0:
                        try:
                            val = int(path[q+6:].split('&')[0])
                            env_monitor.led.set_manual(val)
                        except:
                            pass
            send_response(client, ujson.dumps({'status': 'ok'}))

        elif path.startswith('/fan/'):
            if env_monitor:
                sub = path.split('/fan/')[1]
                if sub == 'on':
                    env_monitor.fan.on()
                elif sub == 'off':
                    env_monitor.fan.off()
                elif sub == 'auto':
                    env_monitor.fan.auto()
                elif sub.startswith('set'):
                    q = path.find('value=')
                    if q > 0:
                        try:
                            val = int(path[q+6:].split('&')[0])
                            env_monitor.fan.set_manual(val)
                        except:
                            pass
            send_response(client, ujson.dumps({'status': 'ok'}))

        # ==================== 门锁API ====================
        elif path == '/status':
            body = ujson.dumps({"status": "open" if door_status else "closed"})
            send_response(client, body)

        elif path == '/ping':
            body = ujson.dumps({"status": "ok", "time": time.ticks_ms()})
            send_response(client, body)

        elif path == '/face_recog':
            lock.acquire()
            body = ujson.dumps({
                "result": face_recog_result,
                "face_count": face_count,
                "name": face_recog_name,
                "score": face_recog_score,
                "threshold": FACE_THRESHOLD
            })
            lock.release()
            send_response(client, body)

        elif path == '/face_image':
            lock.acquire()
            info = detected_face_info.copy() if detected_face_info else None
            has_image = has_new_face_image
            lock.release()

            if has_image and info:
                try:
                    if not send_file_image(client, TEMP_IMAGE_PATH, info):
                        send_response(client, ujson.dumps({"status": "no_face"}))
                except:
                    send_response(client, ujson.dumps({"status": "no_face"}))
            else:
                send_response(client, ujson.dumps({"status": "no_face"}))

        elif path == '/open':
            door_status = 1
            print("[门禁] 远程开门")
            body = ujson.dumps({"status": "open"})
            send_response(client, body)

        elif path == '/close':
            door_status = 0
            print("[门禁] 远程关门")
            body = ujson.dumps({"status": "closed"})
            send_response(client, body)

        elif path == '/register':
            lock.acquire()
            register_request = True
            register_result = {"status": "processing", "message": "处理中..."}
            lock.release()

            for _ in range(50):
                time.sleep_ms(100)
                lock.acquire()
                if register_result["status"] != "processing":
                    result = register_result.copy()
                    lock.release()
                    break
                lock.release()
            else:
                result = {"status": "fail", "message": "超时"}

            result["face_count"] = face_db.count if face_db else 0
            send_response(client, ujson.dumps(result))

        elif path == '/clear_faces':
            if face_db:
                face_db.clear()
                lock.acquire()
                face_count = 0
                face_list = []
                lock.release()
            send_response(client, ujson.dumps({"status": "ok", "face_count": 0}))

        elif path == '/face_list':
            lock.acquire()
            body = ujson.dumps({
                "status": "ok",
                "face_count": face_count,
                "faces": face_list
            })
            lock.release()
            send_response(client, body)

        elif path.startswith('/delete_face/'):
            name = path.split('/delete_face/')[1]
            if name and face_db and face_db.delete(name):
                lock.acquire()
                face_count = face_db.count
                face_list = face_db.names
                lock.release()
                send_response(client, ujson.dumps({"status": "ok", "face_count": face_db.count}))
            else:
                send_response(client, ujson.dumps({"status": "fail", "message": "未找到"}))

        elif path == '/info':
            send_response(client, ujson.dumps({
                "device": "K230",
                "version": "18.0",
                "ip": device_ip,
                "width": WIDTH,
                "height": HEIGHT,
                "threshold": FACE_THRESHOLD
            }))

        else:
            send_response(client, INDEX_HTML, "text/html; charset=utf-8")

    except Exception as e:
        print(f"[HTTP] 请求处理错误: {e}")
    finally:
        try:
            client.close()
        except:
            pass
        gc.collect()

# ==================== HTTP线程 ====================
def http_thread_func():
    global running, http_server
    print("[HTTP线程] 启动")

    while running:
        try:
            try:
                client, addr = http_server.accept()
                handle_request(client, addr)
            except OSError as e:
                if e.args[0] == 11:
                    time.sleep_ms(50)
                else:
                    time.sleep_ms(100)
        except Exception as e:
            print(f"[HTTP线程] 错误: {e}")
            time.sleep_ms(100)

    print("[HTTP线程] 退出")

# ==================== 全局模型变量 ====================
face_det = None
face_reg = None
face_db = None
pl = None

# ==================== 图像格式转换和保存 ====================
_img_debug_done = False

def chw_to_rgb565(chw_array, height, width):
    try:
        if len(chw_array.shape) == 1:
            chw_array = chw_array.reshape((3, height, width))
        r_plane = chw_array[0]
        g_plane = chw_array[1]
        b_plane = chw_array[2]
        pixel_count = height * width
        rgb565 = bytearray(pixel_count * 2)
        for y in range(height):
            for x in range(width):
                idx = y * width + x
                r = int(r_plane[y, x])
                g = int(g_plane[y, x])
                b = int(b_plane[y, x])
                rgb565_val = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                rgb565[idx * 2] = rgb565_val & 0xFF
                rgb565[idx * 2 + 1] = (rgb565_val >> 8) & 0xFF
        return bytes(rgb565)
    except Exception as e:
        print(f"[RGB565转换错误] {e}")
        return None

def save_frame_as_rgb565(ndarray_img, filepath, width, height, quality=50):
    global _img_debug_done
    try:
        start_time = time.ticks_ms()
        rgb565_bytes = chw_to_rgb565(ndarray_img, height, width)
        if rgb565_bytes is None:
            return 0
        img_obj = image.Image(width, height, image.RGB565, data=rgb565_bytes)
        img_obj.save(filepath, quality=quality)
        file_size = os.stat(filepath)[6]
        if not _img_debug_done:
            _img_debug_done = True
            print(f"[保存] {file_size}B")
        del rgb565_bytes
        del img_obj
        return file_size
    except Exception as e:
        print(f"[RGB565保存错误] {e}")
        return 0
    finally:
        gc.collect()

def save_frame_safe(ndarray_img, filepath, width, height, quality=50):
    global save_in_progress
    if save_in_progress:
        return 0
    save_in_progress = True
    file_size = 0
    try:
        file_size = save_frame_as_rgb565(ndarray_img, filepath, width, height, quality)
    except Exception as e:
        print(f"[安全保存错误] {e}")
    finally:
        save_in_progress = False
        gc.collect()
    return file_size

def check_save_interval(face_name, is_known):
    global face_last_save_time
    current_time = time.ticks_ms()
    if is_known:
        key = face_name
        interval = KNOWN_FACE_IMAGE_INTERVAL
    else:
        key = "unknown"
        interval = UNKNOWN_FACE_IMAGE_INTERVAL
    if key in face_last_save_time:
        last_time = face_last_save_time[key]
        elapsed = time.ticks_diff(current_time, last_time)
        if elapsed < interval:
            return False
    return True

def update_save_time(face_name, is_known):
    global face_last_save_time
    if is_known:
        key = face_name
    else:
        key = "unknown"
    face_last_save_time[key] = time.ticks_ms()

def clean_old_save_records():
    global face_last_save_time
    current_time = time.ticks_ms()
    max_age = 10 * 60 * 1000
    keys_to_remove = []
    for key, last_time in face_last_save_time.items():
        elapsed = time.ticks_diff(current_time, last_time)
        if elapsed > max_age:
            keys_to_remove.append(key)
    for key in keys_to_remove:
        del face_last_save_time[key]

# ==================== 主函数 ====================
def main():
    global running, face_det, face_reg, face_db, pl
    global face_recog_result, face_recog_name, face_recog_score, face_count, face_list
    global door_status, register_request, register_result
    global detected_face_info, has_new_face_image
    global env_monitor

    # 1. 连接WiFi
    if not connect_wifi():
        print("[错误] WiFi连接失败")
        return

    # 2. HTTP服务器
    if not init_http():
        print("[错误] HTTP启动失败")
        return

    # 3. 初始化环境监控
    print("\n[环境] 初始化传感器...")
    try:
        env_monitor = EnvMonitor()
        env_monitor.read_chip_temp()
        print(f"[环境] 芯片温度: {env_monitor.chip_temp:.1f}°C")
        print(f"[环境] LED: auto(摄像头) | 风扇: auto")
    except Exception as e:
        print(f"[环境] 初始化失败: {e}")
        env_monitor = None

    # 4. Pipeline
    print("\n[Pipeline] 初始化...")
    try:
        pl = PipeLine(rgb888p_size=[WIDTH, HEIGHT], display_size=[WIDTH, HEIGHT], display_mode="st7701")
        pl.create()
        print("[Pipeline] 成功!")
    except Exception as e:
        print(f"[Pipeline] 错误: {e}")
        return

    # 5. 人脸识别模型
    print("\n[人脸识别] 初始化...")
    try:
        anchors = np.fromfile(ANCHORS_PATH, dtype=np.float)
        anchors = anchors.reshape((4200, 4))

        face_det = FaceDetApp(FACE_DET_KMODEL, model_input_size=[320, 320],
                             anchors=anchors, confidence_threshold=0.5,
                             nms_threshold=0.2, rgb888p_size=[WIDTH, HEIGHT],
                             display_size=[WIDTH, HEIGHT])
        face_det.config_preprocess()

        face_reg = FaceRegApp(FACE_REG_KMODEL, model_input_size=[112, 112],
                             rgb888p_size=[WIDTH, HEIGHT], display_size=[WIDTH, HEIGHT])

        face_db = FaceDatabase(DATABASE_DIR)
        face_count = face_db.count
        face_list = face_db.names
        print("[人脸识别] 成功!")
    except Exception as e:
        print(f"[人脸识别] 错误: {e}")
        face_det = None
        face_reg = None

    # 6. 启动HTTP线程
    _thread.start_new_thread(http_thread_func, ())

    print("\n" + "=" * 50)
    print("  系统启动完成!")
    print(f"  访问: http://{device_ip}:{HTTP_PORT}/")
    print(f"  环境API: /env_status /led/* /fan/*")
    print("=" * 50 + "\n")

    # 7. 主循环
    frame_count = 0
    auto_close_time = 0
    last_clean_time = 0
    last_log_ms = 0
    CLEAN_INTERVAL_MS = 60 * 1000

    print("[主循环] 启动")

    try:
        while running:
            os.exitpoint()

            img = pl.get_frame()

            # 摄像头自动补光
            if env_monitor:
                env_monitor.auto_led(img)

            # 人脸识别
            if face_det and face_reg and img is not None:
                det_boxes, landms = face_det.run(img)

                pl.osd_img.clear()
                local_result = 0
                local_name = ""
                local_score = 0.0

                if det_boxes:
                    for i, (det, landm) in enumerate(zip(det_boxes, landms)):
                        face_reg.config_preprocess(landm)
                        feature = face_reg.run(img)
                        name, score = face_db.search(feature)

                        x1, y1, w, h = map(lambda x: int(round(x, 0)), det[:4])
                        x1 = x1 * WIDTH // ALIGN_UP(WIDTH, 16)
                        w = w * WIDTH // ALIGN_UP(WIDTH, 16)

                        if name:
                            color = (0, 255, 0, 255)
                            label = f"{name}:{score:.2f}"
                            local_result = 1
                            local_name = name
                            local_score = score
                        else:
                            color = (255, 0, 0, 255)
                            label = f"unknown:{score:.2f}"
                            if local_result == 0:
                                local_result = 2
                                local_score = score

                        pl.osd_img.draw_rectangle(x1, y1, w, h, color=color, thickness=3)
                        pl.osd_img.draw_string_advanced(x1, max(0, y1-28), 24, label, color=color)

                    lock.acquire()
                    face_recog_result = local_result
                    face_recog_name = local_name
                    face_recog_score = local_score
                    lock.release()

                    if local_result == 1 and door_status == 0:
                        door_status = 1
                        auto_close_time = time.ticks_ms() + 5000
                        print(f"[门禁] 识别成功: {local_name}, 自动开门")

                    is_known = (local_result == 1)
                    if check_save_interval(local_name if is_known else None, is_known):
                        if not save_in_progress:
                            try:
                                file_size = save_frame_safe(
                                    img, TEMP_IMAGE_PATH, WIDTH, HEIGHT, quality=50)
                                if file_size > 0:
                                    update_save_time(local_name if is_known else None, is_known)
                                    lock.acquire()
                                    detected_face_info = {
                                        "result": local_result,
                                        "name": local_name,
                                        "score": local_score
                                    }
                                    has_new_face_image = True
                                    lock.release()
                                    face_type = local_name if is_known else "陌生人"
                                    print(f"[图片] 保存成功: {face_type}")
                            except Exception as e:
                                print(f"[保存错误] {e}")
                                gc.collect()

                    lock.acquire()
                    should_register = register_request
                    register_request = False
                    lock.release()

                    if should_register:
                        if det_boxes and len(det_boxes) == 1:
                            face_reg.config_preprocess(landms[0])
                            feature = face_reg.run(img)
                            success, msg = face_db.add(feature)
                            lock.acquire()
                            register_result = {"status": "ok" if success else "fail", "message": msg}
                            face_count = face_db.count
                            face_list = face_db.names
                            lock.release()
                            print(f"[注册] {msg}")
                        elif det_boxes and len(det_boxes) > 1:
                            lock.acquire()
                            register_result = {"status": "fail", "message": "检测到多张人脸"}
                            lock.release()
                        else:
                            lock.acquire()
                            register_result = {"status": "fail", "message": "未检测到人脸"}
                            lock.release()
                else:
                    lock.acquire()
                    face_recog_result = 0
                    face_recog_name = ""
                    face_recog_score = 0.0
                    lock.release()
            else:
                lock.acquire()
                face_recog_result = 0
                face_recog_name = ""
                face_recog_score = 0.0
                lock.release()

            # 环境监控 (捕获IDE interrupt等系统异常, 防止终止主循环)
            if env_monitor:
                try:
                    env_monitor.tick()
                except KeyboardInterrupt:
                    raise
                except BaseException as e:
                    print(f"[环境] tick异常: {e}")
                    time.sleep_ms(100)

            # OSD 环境信息显示
            if env_monitor:
                led_text = f"L:{env_monitor.led.duty}%" if env_monitor.led.duty > 0 else "L:OFF"
                fan_text = f"F:{env_monitor.fan.duty}%" if env_monitor.fan.duty > 0 else "F:OFF"
                status_line = f"CPU:{env_monitor.chip_temp:.0f}C {led_text} {fan_text}"
                try:
                    pl.osd_img.draw_string_advanced(10, HEIGHT - 28, 20, status_line,
                                                    color=(255, 255, 200, 255))
                except:
                    pass

            # 自动关门
            if door_status == 1 and auto_close_time > 0 and time.ticks_ms() > auto_close_time:
                door_status = 0
                auto_close_time = 0
                print("[门禁] 自动关门")

            pl.show_image()
            frame_count += 1

            current_time = time.ticks_ms()
            if time.ticks_diff(current_time, last_clean_time) > CLEAN_INTERVAL_MS:
                clean_old_save_records()
                gc.collect()
                last_clean_time = current_time

            if frame_count % 150 == 0:
                gc.collect()

            # 每秒进度日志
            current_time = time.ticks_ms()
            if time.ticks_diff(current_time, last_log_ms) >= 30000:
                last_log_ms = current_time
                env_info = ""
                if env_monitor:
                    env_info = f" CPU:{env_monitor.chip_temp:.0f}C LED:{env_monitor.led.duty}% FAN:{env_monitor.fan.duty}% IP:{device_ip}"
                print(f"[运行] 帧:{frame_count} 人脸:{face_count}{env_info}")

            check_wifi_reconnect()
            time.sleep_ms(20)

    except KeyboardInterrupt:
        print("\n[退出]")
    except Exception as e:
        print(f"[主循环错误] {e}")
    finally:
        running = False
        time.sleep_ms(300)
        # 关闭LED和风扇
        if env_monitor:
            try:
                env_monitor.led.off()
                env_monitor.fan.off()
            except:
                pass
        if face_det:
            try:
                face_det.deinit()
            except:
                pass
        if face_reg:
            try:
                face_reg.deinit()
            except:
                pass
        print("[系统] 已退出")

if __name__ == "__main__":
    os.exitpoint(os.EXITPOINT_ENABLE)
    main()
