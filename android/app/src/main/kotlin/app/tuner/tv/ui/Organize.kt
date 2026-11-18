package app.tuner.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text

/** One action in a long-press menu. */
data class MenuAction(val title: String, val run: () -> Unit)

/**
 * The long-press menu for a channel or category (the Apple apps' context menu): a title and a list of actions.
 * Picking an action closes the menu first; Back or Cancel closes it.
 */
@Composable
fun ItemMenu(title: String, actions: List<MenuAction>, onDismiss: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)), contentAlignment = Alignment.Center) {
        Column(Modifier.width(520.dp).background(TunerColors.surface, RoundedCornerShape(18.dp)).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.headlineSmall, maxLines = 2, modifier = Modifier.padding(start = 12.dp, bottom = 12.dp))
            actions.forEachIndexed { i, action ->
                ListItem(selected = false, onClick = { onDismiss(); action.run() },
                    headlineContent = { Text(action.title) },
                    modifier = Modifier.fillMaxWidth().initialFocus(title, enabled = i == 0))
            }
            ListItem(selected = false, onClick = onDismiss, headlineContent = { Text("Cancel") }, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** Rename a channel or category; an empty name goes back to the provider's. */
@Composable
fun RenameDialog(title: String, current: String, original: String, onSave: (String?) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(current) }
    var focused by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)), contentAlignment = Alignment.Center) {
        Column(Modifier.width(640.dp).background(TunerColors.surface, RoundedCornerShape(18.dp)).padding(28.dp)) {
            Text(title, style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(6.dp))
            Text("Leave empty to use the provider's name, “$original”.", color = Color.White.copy(alpha = 0.7f))
            Spacer(Modifier.height(16.dp))
            BasicTextField(
                text, { text = it }, singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 22.sp),
                cursorBrush = SolidColor(TunerColors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSave(text); onDismiss() }),
                modifier = Modifier.fillMaxWidth().initialFocus(title).onFocusChanged { focused = it.isFocused }
                    .background(if (focused) Color.White.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.3f), RoundedCornerShape(10.dp)).padding(14.dp),
            )
            Spacer(Modifier.height(22.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                PillButton("Save", onClick = { onSave(text); onDismiss() })
                PillButton("Cancel", onClick = onDismiss)
            }
        }
    }
}
