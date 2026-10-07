#!/usr/bin/python3
# L410: panfrost converts a private AFBC resource to u-interleaved on its first CPU write
# instead of a staging BO + blit + flush on every write. Run in the mesa source root.
import sys

P = "src/gallium/drivers/panfrost/pan_resource.c"
s = open(P).read()

HELPER = r'''
/* L410: PAN_AFBC_CPU_WRITE=staging keeps the upstream staging-blit path for CPU
 * writes into AFBC resources (see panfrost_ptr_map). */
static bool
pan_afbc_cpu_write_converts(void)
{
   static int converts = -1;

   if (converts < 0) {
      const char *v = getenv("PAN_AFBC_CPU_WRITE");
      converts = !(v && !strcmp(v, "staging"));
   }
   return converts;
}

static void *
panfrost_ptr_map(struct pipe_context *pctx, struct pipe_resource *resource,
'''
CONVERT = r'''   /* L410: every CPU write into an AFBC resource goes through a staging BO,
    * a blit and a flush (panfrost_ptr_unmap). Toolkits upload icons, glyphs
    * and images that way, texture after texture: a Qt Quick popup made
    * thousands of GPU submissions for its first frame. A private resource
    * the CPU writes to is better off u-interleaved: convert it on its first
    * CPU write, copying its contents if it has any, and let the CPU tile
    * from then on. */
   if ((usage & PIPE_MAP_WRITE) && drm_is_afbc(rsrc->modifier) &&
       pan_afbc_cpu_write_converts() && !rsrc->modifier_constant &&
       !(rsrc->bo->flags & PAN_BO_SHARED) &&
       !(resource->bind & (PIPE_BIND_SHARED | PIPE_BIND_SCANOUT |
                           PIPE_BIND_DISPLAY_TARGET | PIPE_BIND_DEPTH_STENCIL)) &&
       panfrost_should_tile(dev, rsrc, format)) {
      bool has_data = false;

      for (unsigned l = 0; l <= resource->last_level; ++l)
         has_data |= BITSET_TEST(rsrc->valid.data, l);

      pan_resource_modifier_convert(ctx, rsrc,
                                    DRM_FORMAT_MOD_ARM_16X16_BLOCK_U_INTERLEAVED,
                                    has_data, "CPU write to AFBC");
      bo = rsrc->bo;
   }

   /* We don't have s/w routines for AFBC/AFRC, so use a staging texture */
'''

if "pan_afbc_cpu_write_converts" in s:
    print("already patched")
    sys.exit(0)
a = "\nstatic void *\npanfrost_ptr_map(struct pipe_context *pctx, struct pipe_resource *resource,\n"
b = "   /* We don't have s/w routines for AFBC/AFRC, so use a staging texture */\n"
if s.count(a) != 1 or s.count(b) != 1:
    sys.exit("anchors not found")
s = s.replace(a, HELPER, 1).replace(b, CONVERT, 1)
open(P, "w").write(s)
print("patched")
