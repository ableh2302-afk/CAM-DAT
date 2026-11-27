package Com.Camera.dokumentasi

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.Crop
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.RgbMatrix
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Edit video memakai Media3 Transformer: potong durasi, crop, putar/cermin,
 * efek warna, hapus suara, dan overlay (teks / stiker / watermark) dari gambar PNG.
 * Urutan efek: putar -> cermin -> crop -> warna -> overlay.
 */
@OptIn(UnstableApi::class)
class VideoEditor(private val context: Context) {
    private var transformer: Transformer? = null
    private val holder = ProgressHolder()

    /** Persentase 0..100, atau -1 bila belum tersedia. */
    fun progress(): Int {
        val t = transformer ?: return -1
        val state = t.getProgress(holder)
        return if (state == Transformer.PROGRESS_STATE_AVAILABLE) holder.progress else if (state == Transformer.PROGRESS_STATE_WAITING_FOR_AVAILABILITY) 0 else -1
    }

    fun start(args: Map<*, *>, result: MethodChannel.Result) {
        var replied = false
        fun ok(path: String) {
            if (replied) return
            replied = true
            transformer = null
            result.success(path)
        }
        fun fail(msg: String?) {
            if (replied) return
            replied = true
            transformer = null
            result.error("EDIT_FAILED", msg ?: "Gagal memproses video", null)
        }

        try {
            val src = args["src"] as String
            val dest = args["dest"] as String
            val startMs = (args["start"] as? Number)?.toLong() ?: 0L
            val endMs = (args["end"] as? Number)?.toLong() ?: -1L
            val rotation = (args["rotation"] as? Number)?.toInt() ?: 0
            val flip = args["flip"] as? Boolean ?: false
            val crop = (args["crop"] as? List<*>)?.map { (it as Number).toFloat() }
            val filter = args["filter"] as? String ?: "normal"
            val mute = args["mute"] as? Boolean ?: false
            val overlayPath = args["overlay"] as? String

            val clip = MediaItem.ClippingConfiguration.Builder().apply {
                if (startMs > 0) setStartPositionMs(startMs)
                if (endMs > 0) setEndPositionMs(endMs)
            }.build()
            val mediaItem = MediaItem.Builder()
                .setUri(Uri.fromFile(File(src)))
                .setClippingConfiguration(clip)
                .build()

            val fx = ArrayList<Effect>()
            if (rotation % 360 != 0) {
                // Media3 memutar berlawanan arah jarum jam; aplikasi mengirim searah jarum jam.
                fx.add(ScaleAndRotateTransformation.Builder().setRotationDegrees(-rotation.toFloat()).build())
            }
            if (flip) {
                fx.add(ScaleAndRotateTransformation.Builder().setScale(-1f, 1f).build())
            }
            if (crop != null && crop.size == 4) {
                val l = crop[0]
                val t = crop[1]
                val r = crop[2]
                val b = crop[3]
                if (l > 0.001f || t > 0.001f || r < 0.999f || b < 0.999f) {
                    // Koordinat NDC: x -1..1 (kiri ke kanan), y -1..1 (bawah ke atas).
                    fx.add(Crop(-1f + 2f * l, -1f + 2f * r, 1f - 2f * b, 1f - 2f * t))
                }
            }
            when (filter) {
                "mono" -> fx.add(RgbFilter.createGrayscaleFilter())
                "invert" -> fx.add(RgbFilter.createInvertedFilter())
                "sepia" -> fx.add(RgbMatrix { _, _ ->
                    floatArrayOf(
                        0.393f, 0.349f, 0.272f, 0f,
                        0.769f, 0.686f, 0.534f, 0f,
                        0.189f, 0.168f, 0.131f, 0f,
                        0f, 0f, 0f, 1f
                    )
                })
                "warm" -> fx.add(RgbAdjustment.Builder().setRedScale(1.12f).setBlueScale(0.88f).build())
                "cool" -> fx.add(RgbAdjustment.Builder().setRedScale(0.88f).setBlueScale(1.12f).build())
                "bright" -> fx.add(Brightness(0.12f))
                "contrast" -> fx.add(Contrast(0.25f))
            }
            if (overlayPath != null && File(overlayPath).exists()) {
                val bmp = BitmapFactory.decodeFile(overlayPath)
                if (bmp != null) {
                    val overlay = BitmapOverlay.createStaticBitmapOverlay(bmp)
                    fx.add(OverlayEffect(ImmutableList.of<TextureOverlay>(overlay)))
                }
            }

            val edited = EditedMediaItem.Builder(mediaItem)
                .setEffects(Effects(emptyList<AudioProcessor>(), fx))
                .setRemoveAudio(mute)
                .build()

            File(dest).parentFile?.mkdirs()
            val t = Transformer.Builder(context)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        ok(dest)
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        fail(exportException.message)
                    }
                })
                .build()
            transformer = t
            t.start(edited, dest)
        } catch (e: Throwable) {
            fail(e.message)
        }
    }
}
