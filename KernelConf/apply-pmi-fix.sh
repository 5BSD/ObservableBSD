#!/bin/sh
# Apply PMI handler fixes to pt.c
# Run as: doas sh KernelConf/apply-pmi-fix.sh

set -e

FILE="/usr/src/sys/amd64/pt/pt.c"
BACKUP="${FILE}.bak"

cp "$FILE" "$BACKUP"
echo "Backed up to $BACKUP"

# Replace the KASSERT blocks and pt_update_buffer(buf) call in pt_topa_intr
sed -i '' '
/ctx = cpu->ctx;/{
N
/KASSERT(ctx != NULL,/{
N
N
c\
\	ctx = cpu->ctx;\
\	if (ctx == NULL) {\
\		pt_topa_status_clear();\
\		atomic_set_int(\&cpu->in_pcint_handler, 0);\
\		return (1);\
\	}
}
}
/buf = \&ctx->buf;/{
N
/KASSERT(buf->topa_hw != NULL,/{
N
N
c\
\	buf = \&ctx->buf;\
\	if (buf->topa_hw == NULL) {\
\		pt_topa_status_clear();\
\		atomic_set_int(\&cpu->in_pcint_handler, 0);\
\		return (1);\
\	}
}
}
s/pt_update_buffer(buf);/pt_update_buffer(ctx);/
' "$FILE"

echo "Applied PMI handler fixes."
echo "Verify with: grep -n 'ctx == NULL\|topa_hw == NULL\|pt_update_buffer' $FILE | tail -10"
